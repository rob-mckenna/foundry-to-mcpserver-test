param registryName string
param principalId string

// AcrPull built-in role
var acrPullRole = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '7f951dda-4ed3-4680-a7ca-43fe172d538d'
)

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: registryName
}

resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, principalId, acrPullRole)
  scope: registry
  properties: {
    principalId: principalId
    roleDefinitionId: acrPullRole
    principalType: 'ServicePrincipal'
  }
}
