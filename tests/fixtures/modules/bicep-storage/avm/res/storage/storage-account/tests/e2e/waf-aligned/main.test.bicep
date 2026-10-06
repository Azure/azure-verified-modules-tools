targetScope = 'subscription'

metadata name = 'WAF-aligned'
metadata description = 'Compile the secure storage configuration.'

param serviceShort string = 'stgwaf'
param namePrefix string = '#_namePrefix_#'
param resourceLocation string = deployment().location

resource resourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: '${namePrefix}-${serviceShort}'
  location: resourceLocation
}

module testDeployment '../../../main.bicep' = {
  scope: resourceGroup
  name: '${namePrefix}-test-${serviceShort}'
  params: {
    name: 'avm${uniqueString(subscription().subscriptionId, namePrefix, serviceShort)}'
    enableTelemetry: false
  }
}
