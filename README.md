# foundry-to-mcpserver-test

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

### Tear down

```bash
azd down
```

## Connecting Microsoft Foundry

In your existing Microsoft Foundry project, add the MCP server connection:

- **URL**: `https://<SERVICE_MCP_SERVER_URI>/sse`
- **Authentication**: Managed Identity (the project managed identity token is forwarded in the `Authorization: ****** header automatically)

The full token will appear in the Container App log stream immediately on connection.
