# Deploy to an Existing AKS Cluster

This repository supports two deployment paths:

- **Azure Container Apps (ACA)** via `azd up` (default path in the root README)
- **AKS** via Kubernetes manifests and `aks/deploy.sh` (this document)

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

1. Existing AKS cluster and working `kubectl` context.
2. Existing ACR (this repo's ACR or your own).
3. AKS attached to ACR:
   ```bash
   az aks update -g <aks-resource-group> -n <aks-cluster-name> --attach-acr <acr-name>
   ```
4. NGINX Ingress installed (or equivalent ingress controller).
5. DNS hostname mapped to ingress endpoint (required for Microsoft Foundry connection).
6. TLS certificate setup:
   - Either cert-manager + ClusterIssuer, or
   - Pre-created TLS secret.
7. Azure CLI, kubectl, and `envsubst`.

Install ingress-nginx example:

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

Common optional overrides:

```bash
export IMAGE_TAG=<tag>                          # default: current git short SHA
export TLS_SECRET_NAME=mcp-server-tls
export CERT_MANAGER_CLUSTER_ISSUER=letsencrypt-prod
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

1. Build and push image to ACR (`az acr build` by default).
2. Render manifests with `envsubst`.
3. Apply namespace, configmap, deployment, service, and ingress.
4. Wait for rollout completion and print MCP URL.
5. Optionally run smoke test.

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
