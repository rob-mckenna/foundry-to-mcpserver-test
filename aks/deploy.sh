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
