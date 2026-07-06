#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd az
require_cmd kubectl
require_cmd envsubst

ACR_NAME="${ACR_NAME:-}"
MCP_HOST="${MCP_HOST:-}"
NAMESPACE="${NAMESPACE:-mcp-server}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)}"
TLS_SECRET_NAME="${TLS_SECRET_NAME:-mcp-server-tls}"
CERT_MANAGER_CLUSTER_ISSUER="${CERT_MANAGER_CLUSTER_ISSUER:-}"
USE_ACR_BUILD="${USE_ACR_BUILD:-true}"
APPLY_SECRET_TEMPLATE="${APPLY_SECRET_TEMPLATE:-false}"
RUN_SMOKE_TEST="${RUN_SMOKE_TEST:-false}"
CREATE_AKS_IF_MISSING="${CREATE_AKS_IF_MISSING:-false}"
AKS_RESOURCE_GROUP="${AKS_RESOURCE_GROUP:-}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-}"
AKS_LOCATION="${AKS_LOCATION:-${AZURE_LOCATION:-eastus}}"
AKS_NODE_COUNT="${AKS_NODE_COUNT:-1}"
AKS_NODE_VM_SIZE="${AKS_NODE_VM_SIZE:-Standard_D4s_v3}"
AKS_KUBERNETES_VERSION="${AKS_KUBERNETES_VERSION:-}"
ATTACH_ACR="${ATTACH_ACR:-true}"
INSTALL_INGRESS_NGINX="${INSTALL_INGRESS_NGINX:-false}"

AUTH_REQUIRED="${AUTH_REQUIRED:-true}"
AUTH_AUDIENCE="${AUTH_AUDIENCE:-api://7d019514-b7a5-4501-9baa-099a4e0a627c}"
AUTH_TENANT_ID="${AUTH_TENANT_ID:-$(az account show --query tenantId -o tsv)}"
AUTH_REQUIRED_ROLES="${AUTH_REQUIRED_ROLES:-mcp-srv-001}"
AUTH_ACCEPT_SCOPES="${AUTH_ACCEPT_SCOPES:-}"
ALLOWED_ORIGINS="${ALLOWED_ORIGINS:-http://localhost:6274}"

if [[ -z "${ACR_NAME}" ]]; then
  echo "Set ACR_NAME (e.g. export ACR_NAME=myregistry)" >&2
  exit 1
fi

if [[ -z "${MCP_HOST}" ]]; then
  echo "Set MCP_HOST (e.g. export MCP_HOST=mcp.example.com)" >&2
  exit 1
fi

ACR_LOGIN_SERVER="${ACR_LOGIN_SERVER:-$(az acr show -n "${ACR_NAME}" --query loginServer -o tsv)}"

if [[ -n "${AKS_RESOURCE_GROUP}" || -n "${AKS_CLUSTER_NAME}" || "${CREATE_AKS_IF_MISSING}" == "true" ]]; then
  if [[ -z "${AKS_RESOURCE_GROUP}" || -z "${AKS_CLUSTER_NAME}" ]]; then
    echo "Set both AKS_RESOURCE_GROUP and AKS_CLUSTER_NAME when using AKS cluster management options." >&2
    exit 1
  fi

  if az aks show -g "${AKS_RESOURCE_GROUP}" -n "${AKS_CLUSTER_NAME}" >/dev/null 2>&1; then
    echo "Using existing AKS cluster ${AKS_CLUSTER_NAME} in ${AKS_RESOURCE_GROUP}."
  else
    if [[ "${CREATE_AKS_IF_MISSING}" != "true" ]]; then
      echo "AKS cluster ${AKS_CLUSTER_NAME} not found in ${AKS_RESOURCE_GROUP}. Set CREATE_AKS_IF_MISSING=true to create it." >&2
      exit 1
    fi

    echo "Creating resource group ${AKS_RESOURCE_GROUP} in ${AKS_LOCATION}."
    az group create -n "${AKS_RESOURCE_GROUP}" -l "${AKS_LOCATION}" >/dev/null

    echo "Creating AKS cluster ${AKS_CLUSTER_NAME}."
    aks_create_cmd=(az aks create
      -g "${AKS_RESOURCE_GROUP}"
      -n "${AKS_CLUSTER_NAME}"
      -l "${AKS_LOCATION}"
      --node-count "${AKS_NODE_COUNT}"
      --node-vm-size "${AKS_NODE_VM_SIZE}"
      --enable-managed-identity
      --generate-ssh-keys)

    if [[ -n "${AKS_KUBERNETES_VERSION}" ]]; then
      aks_create_cmd+=(--kubernetes-version "${AKS_KUBERNETES_VERSION}")
    fi

    if [[ "${ATTACH_ACR}" == "true" ]]; then
      aks_create_cmd+=(--attach-acr "${ACR_NAME}")
    fi

    "${aks_create_cmd[@]}"
  fi

  echo "Fetching AKS credentials."
  az aks get-credentials -g "${AKS_RESOURCE_GROUP}" -n "${AKS_CLUSTER_NAME}" --overwrite-existing

  if [[ "${ATTACH_ACR}" == "true" ]]; then
    echo "Ensuring AKS cluster has ACR pull access."
    az aks update -g "${AKS_RESOURCE_GROUP}" -n "${AKS_CLUSTER_NAME}" --attach-acr "${ACR_NAME}" >/dev/null
  fi
fi

if [[ "${INSTALL_INGRESS_NGINX}" == "true" ]]; then
  require_cmd helm
  echo "Installing/upgrading ingress-nginx."
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace
fi

if [[ "${USE_ACR_BUILD}" == "true" ]]; then
  az acr build \
    -r "${ACR_NAME}" \
    -t "mcp-server:${IMAGE_TAG}" \
    "${REPO_ROOT}/mcp-server"
else
  require_cmd docker
  az acr login -n "${ACR_NAME}"
  docker build -t "${ACR_LOGIN_SERVER}/mcp-server:${IMAGE_TAG}" "${REPO_ROOT}/mcp-server"
  docker push "${ACR_LOGIN_SERVER}/mcp-server:${IMAGE_TAG}"
fi

TMP_DIR="$(mktemp -d /tmp/mcp-aks-manifests.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

export ACR_LOGIN_SERVER IMAGE_TAG MCP_HOST TLS_SECRET_NAME CERT_MANAGER_CLUSTER_ISSUER
export AUTH_REQUIRED AUTH_AUDIENCE AUTH_TENANT_ID AUTH_REQUIRED_ROLES AUTH_ACCEPT_SCOPES ALLOWED_ORIGINS

for file in namespace.yaml configmap.yaml secret.yaml deployment.yaml service.yaml ingress.yaml; do
  envsubst < "${MANIFEST_DIR}/${file}" > "${TMP_DIR}/${file}"
done

kubectl apply -f "${TMP_DIR}/namespace.yaml"
kubectl apply -f "${TMP_DIR}/configmap.yaml"
if [[ "${APPLY_SECRET_TEMPLATE}" == "true" ]]; then
  kubectl apply -f "${TMP_DIR}/secret.yaml"
else
  echo "Skipping secret template apply (set APPLY_SECRET_TEMPLATE=true to apply aks/manifests/secret.yaml)."
fi
kubectl apply -f "${TMP_DIR}/deployment.yaml"
kubectl apply -f "${TMP_DIR}/service.yaml"
kubectl apply -f "${TMP_DIR}/ingress.yaml"

kubectl rollout status deployment/mcp-server -n "${NAMESPACE}"

INGRESS_ADDR="$(kubectl get ingress mcp-server -n "${NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
if [[ -z "${INGRESS_ADDR}" ]]; then
  INGRESS_ADDR="$(kubectl get ingress mcp-server -n "${NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
fi

echo "Deployment complete."
echo "MCP SSE URL: https://${MCP_HOST}/sse"
if [[ -n "${INGRESS_ADDR}" ]]; then
  echo "Ingress address: ${INGRESS_ADDR}"
fi

echo "To stream logs: kubectl logs -n ${NAMESPACE} -l app=mcp-server -f"

if [[ "${RUN_SMOKE_TEST}" == "true" ]]; then
  (
    cd "${REPO_ROOT}/mcp-server"
    if [[ -n "${MCP_BEARER_TOKEN:-}" ]]; then
      MCP_SERVER_URL="https://${MCP_HOST}" MCP_BEARER_TOKEN="${MCP_BEARER_TOKEN}" npm run smoke
    else
      MCP_SERVER_URL="https://${MCP_HOST}" npm run smoke
    fi
  )
fi
