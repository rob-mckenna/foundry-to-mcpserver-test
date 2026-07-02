# MS Foundry to MCP Server / Managed Identity (Entra ID) Testing

Testing Microsoft Foundry sending a Managed Identity (Entra ID) token to an MCP Server deployed on Azure Container Apps.

## Architecture

```
Microsoft Foundry
  └── Project Managed Identity (Entra ID token)
        └── HTTPS → Azure Container App
                        └── MCP Server (Node.js)
                              ├── Logs full request (incl. Authorization header) for troubleshooting
                              └── Tool: get_weather
```

### Resources deployed

| Resource | Purpose |
|---|---|
| Azure Container Registry | Stores the MCP server container image |
| Azure Container Apps Environment | Hosts the Container App |
| Azure Container App | Runs the MCP server; tagged `azd-service-name: mcp-server` |
| User-Assigned Managed Identity | Allows the Container App to pull from ACR (AcrPull) |
| Log Analytics Workspace | Receives Container App console logs |

## MCP Endpoints

| Endpoint | Description |
|---|---|
| `GET /sse` | SSE endpoint – Microsoft Foundry connects here to establish an MCP session |
| `POST /messages?sessionId=<id>` | JSON-RPC message endpoint |
| `GET /health` | Health check / liveness probe |

## Security settings

The server can validate Entra bearer tokens and restrict browser origins for MCP Inspector.

Configured via environment variables (wired through `infra/main.parameters.json`):

- `MCP_AUTH_REQUIRED` (default: `true`)
- `MCP_AUTH_AUDIENCE` (default: `api://7d019514-b7a5-4501-9baa-099a4e0a627c`)
- `MCP_AUTH_REQUIRED_ROLES` (default: `mcp-srv-001`)
- `MCP_AUTH_ACCEPT_SCOPES` (default: empty; optional delegated fallback, e.g. `Mcp.Invoke`)
- `MCP_ALLOWED_ORIGINS` (default: `http://localhost:6274`)

Token validation uses tenant discovery keys and checks:

- issuer = `https://login.microsoftonline.com/<tenant-id>/v2.0`
- audience = `MCP_AUTH_AUDIENCE`
- authorization = token must contain at least one role from `MCP_AUTH_REQUIRED_ROLES`
  (or one scope from `MCP_AUTH_ACCEPT_SCOPES` when configured)

Auth response semantics:

- `401 Unauthorized` → missing/invalid bearer token or issuer/audience mismatch
- `403 Forbidden` → valid token but missing required role/scope

> Role assignment changes can take time to appear due to managed-identity token caching.
> A newly assigned app role may not show up until a new token is minted.

### App-role authorization prerequisites

Before enabling role enforcement, make sure these exist:

1. Microsoft Entra app registration for the MCP API (the `MCP_AUTH_AUDIENCE` app ID URI, for example `api://<app-id>`).
2. App role on that API with value matching `MCP_AUTH_REQUIRED_ROLES` (default `mcp-srv-001`).
3. App role `allowedMemberTypes` includes `Application` (required for managed identity tokens).
4. Foundry project connection to this MCP server uses:
   - Authentication: **Project managed identity**
   - Audience: same value as `MCP_AUTH_AUDIENCE`
5. Foundry project managed identity service principal is assigned the app role on the MCP API service principal.

### Required Microsoft Entra ID configuration

Use these steps for the MCP API app registration:

1. **Define app role** on the app registration (example value: `mcp-srv-001`).
2. **Create/confirm service principal** for that app registration in the tenant.
3. **Assign role to Foundry project managed identity** (service principal to service principal assignment):
   - principal = Foundry project MI service principal object ID
   - resource = MCP API service principal object ID
   - appRoleId = role ID for `mcp-srv-001`
4. Confirm the Foundry connection audience equals the API app ID URI (`api://...`).

> If role assignment was just added, expect delay until a fresh managed-identity token is minted.

### Implementation / deployment steps

1. Configure auth variables:
   ```bash
   azd env set MCP_AUTH_REQUIRED true
   azd env set MCP_AUTH_AUDIENCE "api://<mcp-api-app-id>"
   azd env set MCP_AUTH_REQUIRED_ROLES "mcp-srv-001"
   azd env set MCP_AUTH_ACCEPT_SCOPES ""  # optional fallback; keep empty for strict app-role auth
   ```
2. Deploy:
   ```bash
   azd deploy
   ```
3. Verify Container App env includes:
   - `AUTH_REQUIRED=true`
   - `AUTH_AUDIENCE=<api://...>`
   - `AUTH_REQUIRED_ROLES=mcp-srv-001`

### Test matrix (what to verify)

| Scenario | Expected result |
|---|---|
| No bearer token | `401` |
| Invalid signature / wrong issuer / wrong audience | `401` |
| Valid token without required role/scope | `403` |
| Valid token with `roles` containing `mcp-srv-001` | `/sse` and `/messages` succeed |

Recommended verification path:

1. Trigger MCP calls from Foundry Playground.
2. Inspect Container App logs for `/sse` and `/messages` requests.
3. Decode captured token and verify claims:
   - `aud` = `MCP_AUTH_AUDIENCE`
   - `roles` contains required role value (`mcp-srv-001`)
4. If role is missing but assignment is correct, wait for token refresh and re-test.

Example to allow two Inspector origins:

```bash
azd env set MCP_ALLOWED_ORIGINS "http://localhost:6274,https://inspector.modelcontextprotocol.io"
azd deploy
```

### Tool: `get_weather`

```json
{
  "tool": "get_weather",
  "arguments": { "location": "Dublin, Ireland" }
}
```

Returns mock weather data (temperature, condition, humidity, wind, UV index).

## Request logging

Every inbound HTTP request is logged to stdout as structured JSON, including all headers.  
The `authorization` field carries the ****** sent by Microsoft Foundry, which you can inspect in **Log Analytics** or via the Azure Portal → Container App → Log stream.

```json
{
  "timestamp": "2025-01-01T12:00:00.000Z",
  "remoteAddress": "20.x.x.x",
  "method": "GET",
  "url": "/sse",
  "headers": {
    "authorization": "******",
    ...
  }
}
```

## Prerequisites

- [Azure Developer CLI (azd)](https://aka.ms/azd) ≥ 1.9
- [Docker](https://docs.docker.com/get-docker/) (running locally for `azd up`)
- An Azure subscription
- **An existing Microsoft Foundry resource and project** (with project managed identity enabled for token acquisition)

## Deploy with `azd up`

```bash
# 1. Authenticate
azd auth login

# 2. Initialise environment (choose a short env name, e.g. "mcp-dev")
azd env new <env-name>
azd env set AZURE_LOCATION eastus   # or any supported region

# 3. Provision infrastructure + build & deploy the container in one step
azd up
```

`azd up` will:
1. Create the resource group and all Azure resources (via `infra/main.bicep`)
2. Build the Docker image from `mcp-server/Dockerfile`
3. Push it to the provisioned Azure Container Registry
4. Deploy it to the Container App

The MCP server URL is printed at the end:

```
SERVICE_MCP_SERVER_URI = https://ca-mcp-<token>.azurecontainerapps.io
```

### Subsequent deployments

```bash
azd deploy        # redeploy the app only (no infra changes)
azd provision     # reprovision infra only
azd up            # both
```

## Smoke test after deploy

Run an end-to-end MCP handshake check (health, SSE endpoint event, and initialize call):

```bash
cd mcp-server
MCP_SERVER_URL="https://<SERVICE_MCP_SERVER_URI_HOST>" \
MCP_BEARER_TOKEN="$(az account get-access-token --resource api://7d019514-b7a5-4501-9baa-099a4e0a627c --query accessToken -o tsv)" \
npm run smoke
```

If you disabled auth (`MCP_AUTH_REQUIRED=false`), omit `MCP_BEARER_TOKEN`.

### Tear down

```bash
azd down
```

## Connecting Microsoft Foundry

In your existing Microsoft Foundry project, add the MCP server connection:

- **URL**: `https://<SERVICE_MCP_SERVER_URI>/sse`
- **Authentication**: Managed Identity (the project managed identity token is forwarded in the `Authorization: ****** header automatically)

The full token will appear in the Container App log stream immediately on connection.
