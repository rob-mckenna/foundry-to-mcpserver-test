# Deploy to AKS (Existing or New Cluster)

This repository supports two deployment paths:

- **Azure Container Apps (ACA)** via `azd up` (default path in the root README)
- **AKS** via Kubernetes manifests and `aks/deploy.sh` (this document; supports existing or new cluster)

The AKS path is intentionally manual and parallel to ACA. It does not integrate with `azd` service hosting because `azure.yaml` uses `host: containerapp`.

## Architecture (AKS)

```
Microsoft Foundry
  └── Project Managed Identity (Entra ID token)
        └── HTTPS → NGINX Ingress
                      └── Kubernetes Service (ClusterIP)
                            └── Deployment (1 replica)
                                  └── MCP Server Pod (Node.js)
```

## Prerequisites

1. Existing ACR (this repo's ACR or your own).
2. AKS cluster path:
   - Existing cluster, or
   - Let `aks/deploy.sh` create one for you.
3. DNS hostname mapped to ingress endpoint (required for Microsoft Foundry connection).
4. TLS certificate setup:
   - Either cert-manager + ClusterIssuer, or
   - Pre-created TLS secret.
5. Azure CLI, kubectl, and `envsubst`.

Install ingress-nginx example (if not installed and not using `INSTALL_INGRESS_NGINX=true`):

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace
```

## Files

- `aks/deploy.sh` – build/push/deploy workflow
- `aks/manifests/namespace.yaml`
- `aks/manifests/configmap.yaml`
- `aks/manifests/secret.yaml` (template only)
- `aks/manifests/deployment.yaml`
- `aks/manifests/service.yaml`
- `aks/manifests/ingress.yaml`

## Configure deployment values

Required:

```bash
export ACR_NAME=<acr-name>
export MCP_HOST=<public-mcp-hostname>  # example: mcp.example.com
```

### Existing cluster workflow

Use your current kube context, or set cluster identifiers so the script fetches credentials:

```bash
export AKS_RESOURCE_GROUP=<aks-resource-group>
export AKS_CLUSTER_NAME=<aks-cluster-name>
```

If `AKS_RESOURCE_GROUP` and `AKS_CLUSTER_NAME` are set, `deploy.sh` runs:

- `az aks get-credentials --overwrite-existing`
- `az aks update --attach-acr` (unless `ATTACH_ACR=false`)

### New cluster workflow (create if missing)

```bash
export AKS_RESOURCE_GROUP=<aks-resource-group>
export AKS_CLUSTER_NAME=<new-aks-cluster-name>
export CREATE_AKS_IF_MISSING=true
```

Optional create parameters:

```bash
export AKS_LOCATION=eastus
export AKS_NODE_COUNT=1
export AKS_NODE_VM_SIZE=Standard_D4s_v3
export AKS_KUBERNETES_VERSION=1.30.0
```

When enabled, the script creates resource group and AKS cluster if it does not already exist.

Common optional overrides:

```bash
export IMAGE_TAG=<tag>                          # default: current git short SHA
export TLS_SECRET_NAME=mcp-server-tls
export CERT_MANAGER_CLUSTER_ISSUER=letsencrypt-prod
export INSTALL_INGRESS_NGINX=true              # install/upgrade ingress-nginx with Helm
export ATTACH_ACR=true                         # default true
export AUTH_REQUIRED=true
export AUTH_AUDIENCE=api://<mcp-api-app-id>
export AUTH_TENANT_ID=<tenant-id>
export AUTH_REQUIRED_ROLES=mcp-srv-001
export AUTH_ACCEPT_SCOPES=
export ALLOWED_ORIGINS=http://localhost:6274
```

## Deploy

From repository root:

```bash
./aks/deploy.sh
```

`deploy.sh` phases:

1. Optionally create AKS cluster if missing (`CREATE_AKS_IF_MISSING=true`).
2. Fetch AKS credentials and ensure ACR attachment (unless `ATTACH_ACR=false`).
3. Optionally install ingress-nginx (`INSTALL_INGRESS_NGINX=true`).
4. Build and push image to ACR (`az acr build` by default).
5. Render manifests with `envsubst`.
6. Apply namespace, configmap, deployment, service, and ingress.
7. Wait for rollout completion and print MCP URL.
8. Optionally run smoke test.

### Optional behaviors

- Use local Docker build/push instead of ACR Tasks:
  ```bash
  export USE_ACR_BUILD=false
  ./aks/deploy.sh
  ```
- Apply secret template (not recommended until placeholders are replaced):
  ```bash
  export APPLY_SECRET_TEMPLATE=true
  ./aks/deploy.sh
  ```
- Run smoke test after deploy:
  ```bash
  export RUN_SMOKE_TEST=true
  export MCP_BEARER_TOKEN=<token-if-auth-required>
  ./aks/deploy.sh
  ```
- Full create-and-deploy in one flow:
  ```bash
  export ACR_NAME=<acr-name>
  export MCP_HOST=<mcp-hostname>
  export AKS_RESOURCE_GROUP=<aks-rg>
  export AKS_CLUSTER_NAME=<aks-name>
  export CREATE_AKS_IF_MISSING=true
  export INSTALL_INGRESS_NGINX=true
  ./aks/deploy.sh
  ```

## Secret template usage

`aks/manifests/secret.yaml` is committed as a **template** and contains `REPLACE_ME` values. Do not apply it unchanged in production.

If you use secrets, replace values first, then apply explicitly:

```bash
kubectl apply -f aks/manifests/secret.yaml
```

## Verify deployment

```bash
kubectl get pods -n mcp-server
kubectl rollout status deployment/mcp-server -n mcp-server
kubectl logs -n mcp-server -l app=mcp-server -f
```

MCP endpoint for Microsoft Foundry:

```
https://<MCP_HOST>/sse
```

## Connect Microsoft Foundry

In your Microsoft Foundry project MCP connection:

- URL: `https://<MCP_HOST>/sse`
- Authentication: **Managed identity**
- Audience: same as `AUTH_AUDIENCE`

## Teardown

```bash
kubectl delete namespace mcp-server
```

## Scaling limitation

This MCP server currently keeps SSE session state in process memory. Keep `replicas: 1`.

If replicas are increased without shared session storage, `/messages` may land on a different pod than `/sse` and fail session lookup.

For true horizontal scaling, use a shared session backend (for example Redis) or migrate to a transport model that is not instance-affine.

## AKS vs ACA summary

| Aspect | Azure Container Apps (azd) | AKS (manual) |
|---|---|---|
| Provisioning | `azd up` / Bicep | `./aks/deploy.sh` + `kubectl apply` |
| TLS | Managed by ACA endpoint | Ingress + cert-manager (or pre-created cert) |
| ACR auth | Managed identity in Bicep | AKS attached to ACR |
| Replicas | `maxReplicas: 1` | `replicas: 1` |
| Logs | Log Analytics / portal | `kubectl logs` |
| URL | `*.azurecontainerapps.io` | User DNS hostname |
| Config | `azd env set` + Bicep params | Env vars + manifest rendering |
