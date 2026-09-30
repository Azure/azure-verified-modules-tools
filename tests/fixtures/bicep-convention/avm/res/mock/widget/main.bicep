metadata name = 'Mock widget'
metadata description = 'Deploys a mock widget.'

@description('Required. Widget name.')
param name string

resource widget 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: resourceGroup().location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
}
