targetScope = 'subscription'

// ─────────────────────────────────────────────────────────────────────────────
// Parameters
// ─────────────────────────────────────────────────────────────────────────────

@minLength(1)
@maxLength(64)
@description('Name of the azd environment (used as a base for all resource names)')
param environmentName string

@minLength(1)
@description('Primary Azure region for all resources')
param location string

@description('Set automatically by azd on re-provision when the Container App already exists')
param mcpServerExists bool = false

@description('OAuth audience expected in incoming Entra access tokens')
param authAudience string = 'api://7d019514-b7a5-4501-9baa-099a4e0a627c'

@description('Whether the MCP server enforces bearer token validation')
param authRequired bool = true

@description('Comma-separated app role values required in the token roles claim')
param authRequiredRoles string = 'mcp-srv-001'

@description('Optional comma-separated delegated scopes accepted as fallback')
param authAcceptScopes string = ''

@description('Comma-separated list of allowed browser origins for CORS')
param allowedOrigins string = 'http://localhost:6274'

// ─────────────────────────────────────────────────────────────────────────────
// Variables
// ─────────────────────────────────────────────────────────────────────────────

var tags = { 'azd-env-name': environmentName }
var abbrs = loadJsonContent('./abbreviations.json')

// Unique token scoped to subscription + environment + region so resource names
// don't collide across environments while remaining stable on re-provision.
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))

// ─────────────────────────────────────────────────────────────────────────────
// Resource group
// ─────────────────────────────────────────────────────────────────────────────

resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared infrastructure
// ─────────────────────────────────────────────────────────────────────────────

module logAnalytics 'modules/log-analytics.bicep' = {
  name: 'log-analytics'
  scope: rg
  params: {
    name: '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    location: location
    tags: tags
  }
}

module registry 'modules/container-registry.bicep' = {
  name: 'container-registry'
  scope: rg
  params: {
    name: '${abbrs.containerRegistryRegistries}${resourceToken}'
    location: location
    tags: tags
  }
}

// User-assigned managed identity – used by the Container App to pull images
// from ACR without storing credentials.
module identity 'modules/managed-identity.bicep' = {
  name: 'managed-identity'
  scope: rg
  params: {
    name: '${abbrs.managedIdentityUserAssignedIdentities}${resourceToken}'
    location: location
    tags: tags
  }
}

module registryAccess 'modules/registry-access.bicep' = {
  name: 'registry-access'
  scope: rg
  params: {
    registryName: registry.outputs.name
    principalId: identity.outputs.principalId
  }
}

module containerAppsEnv 'modules/container-apps-environment.bicep' = {
  name: 'container-apps-environment'
  scope: rg
  params: {
    name: '${abbrs.appManagedEnvironments}${resourceToken}'
    location: location
    tags: tags
    logAnalyticsWorkspaceName: logAnalytics.outputs.name
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MCP Server Container App
// Tagged with azd-service-name so azd can locate it during `azd deploy`.
// ─────────────────────────────────────────────────────────────────────────────

module mcpServer 'modules/mcp-server.bicep' = {
  name: 'mcp-server'
  scope: rg
  params: {
    name: '${abbrs.appContainerApps}mcp-${resourceToken}'
    location: location
    tags: union(tags, { 'azd-service-name': 'mcp-server' })
    identityName: identity.outputs.name
    containerAppsEnvironmentName: containerAppsEnv.outputs.name
    containerRegistryName: registry.outputs.name
    appExists: mcpServerExists
    authRequired: authRequired
    authAudience: authAudience
    authTenantId: tenant().tenantId
    authRequiredRoles: authRequiredRoles
    authAcceptScopes: authAcceptScopes
    allowedOrigins: allowedOrigins
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Outputs consumed by azd and downstream tooling
// ─────────────────────────────────────────────────────────────────────────────

output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output AZURE_RESOURCE_GROUP string = rg.name

// Required by azd to push the built container image to ACR
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = registry.outputs.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = registry.outputs.name

// Convenience outputs
output SERVICE_MCP_SERVER_URI string = mcpServer.outputs.uri
output SERVICE_MCP_SERVER_NAME string = mcpServer.outputs.name
