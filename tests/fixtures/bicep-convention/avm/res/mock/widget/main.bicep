metadata name = 'Mock widget'
metadata description = 'Deploys a mock widget.'

@description('Required. Widget name.')
param name string

@description('Optional. Enable/Disable usage telemetry for module.')
param enableTelemetry bool = true

var telemetryIdPrefix = loadJsonContent('metadata.json', 'telemetryIdPrefix')

resource widget 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: resourceGroup().location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
}

resource telemetry 'Microsoft.Resources/deployments@2022-09-01' = if (enableTelemetry) {
  name: '${telemetryIdPrefix}-test'
  properties: {
    mode: 'Incremental'
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
      contentVersion: '1.0.0.0'
      resources: []
      outputs: {
        telemetry: {
          type: 'string'
          value: 'For more information, see https://aka.ms/avm/TelemetryInfo'
        }
      }
    }
  }
}

@description('The widget name.')
output name string = widget.name

@description('The widget resource ID.')
output resourceId string = widget.id

@description('The widget location.')
output location string = widget.location

@description('The widget resource group name.')
output resourceGroupName string = resourceGroup().name
