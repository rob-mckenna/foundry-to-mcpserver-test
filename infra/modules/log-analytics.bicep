param name string
param location string
param tags object = {}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

output name string = logAnalytics.name
output id string = logAnalytics.id
output customerId string = logAnalytics.properties.customerId
