metadata name = 'Storage Demo'
metadata description = 'Deploys a small storage account for documentation tests.'

@description('Required. Globally unique storage account name.')
param name string

@description('Optional. Resource location.')
param location string = resourceGroup().location

resource account 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
}

@description('The resource ID.')
output resourceId string = account.id
