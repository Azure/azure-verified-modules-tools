targetScope = 'resourceGroup'

metadata name = 'Storage Account'
metadata description = 'This module deploys a storage account.'

type tagsType = {
  *: string
}

@description('Required. The name of the storage account.')
param name string

@description('Optional. The location of the storage account.')
param location string = resourceGroup().location

@description('Optional. Tags of the storage account.')
param tags tagsType?

@description('Optional. Require secure transport for storage requests.')
param supportsHttpsTrafficOnly bool = true

@description('Optional. Enable/disable usage telemetry for this module.')
param enableTelemetry bool = true

var avmTelemetryIdPrefix = loadJsonContent('metadata.json', '$.telemetryIdPrefix')

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-06-01' = {
  name: name
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_ZRS'
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: supportsHttpsTrafficOnly
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    encryption: {
      keySource: 'Microsoft.Storage'
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-06-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

#disable-next-line no-deployments-resources
resource avmTelemetry 'Microsoft.Resources/deployments@2025-04-01' = if (enableTelemetry) {
  name: '${avmTelemetryIdPrefix}.${uniqueString(resourceGroup().id)}'
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

@description('The name of the storage account.')
output name string = storageAccount.name

@description('The resource ID of the storage account.')
output resourceId string = storageAccount.id

@description('The location of the storage account.')
output location string = storageAccount.location

@description('The name of the resource group.')
output resourceGroupName string = resourceGroup().name
