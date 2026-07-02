@description('Name of the Container App')
param name string

@description('Azure region')
param location string

param tags object = {}
param identityName string
param containerAppsEnvironmentName string
param containerRegistryName string
param authRequired bool = true
param authAudience string
param authTenantId string
param authRequiredRoles string = 'mcp-srv-001'
param authAcceptScopes string = ''
param allowedOrigins string = 'http://localhost:6274'

@description('Set to true on re-provision to preserve the running image instead of resetting to the placeholder')
param appExists bool = false

// Placeholder used only on first provision; azd deploy replaces it with the real image
var placeholderImage = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2023-05-01' existing = {
  name: containerAppsEnvironmentName
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: containerRegistryName
}

// Read the current image from an already-deployed app so re-provisioning does
// not reset a live deployment back to the placeholder.
module fetchLatestImage 'fetch-latest-image.bicep' = {
  name: '${deployment().name}-fetch-latest-image'
  params: {
    exists: appExists
    name: name
  }
}

var currentImage = length(fetchLatestImage.outputs.containers) > 0
  ? fetchLatestImage.outputs.containers[0].image
  : placeholderImage

resource app 'Microsoft.App/containerApps@2023-05-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppsEnvironment.id
    configuration: {
      ingress: {
        external: true
        targetPort: 3000
        transport: 'http'
        allowInsecure: false
      }
      registries: [
        {
          server: registry.properties.loginServer
          identity: identity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'mcp-server'
          image: currentImage
          env: [
            {
              name: 'PORT'
              value: '3000'
            }
            {
              name: 'NODE_ENV'
              value: 'production'
            }
            {
              name: 'AUTH_REQUIRED'
              value: string(authRequired)
            }
            {
              name: 'AUTH_AUDIENCE'
              value: authAudience
            }
            {
              name: 'AUTH_TENANT_ID'
              value: authTenantId
            }
            {
              name: 'AUTH_REQUIRED_ROLES'
              value: authRequiredRoles
            }
            {
              name: 'AUTH_ACCEPT_SCOPES'
              value: authAcceptScopes
            }
            {
              name: 'ALLOWED_ORIGINS'
              value: allowedOrigins
            }
          ]
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/health'
                port: 3000
              }
              initialDelaySeconds: 10
              periodSeconds: 30
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/health'
                port: 3000
              }
              initialDelaySeconds: 5
              periodSeconds: 10
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        // SSE sessions are stored in-memory per replica; keep single replica
        // so /sse and /messages for the same session always hit the same host.
        maxReplicas: 1
      }
    }
  }
}

output name string = app.name
output uri string = 'https://${app.properties.configuration.ingress.fqdn}'
output id string = app.id
