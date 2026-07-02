@description('Whether the Container App already exists from a previous deployment')
param exists bool

@description('Name of the existing Container App to read')
param name string

resource existingApp 'Microsoft.App/containerApps@2023-05-01' existing = if (exists) {
  name: name
}

output containers array = exists ? existingApp.properties.template.containers : []
