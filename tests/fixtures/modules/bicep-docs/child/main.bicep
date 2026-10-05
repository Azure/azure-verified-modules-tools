metadata name = 'Child Demo'
metadata description = 'Deploys a child of the storage account.'

@description('Required. Parent storage account name.')
param parentName string

@description('Required. Blob container name.')
param name string

resource account 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: parentName
}

resource blob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: account
  name: 'default'
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blob
  name: name
  properties: {
    publicAccess: 'None'
  }
}
