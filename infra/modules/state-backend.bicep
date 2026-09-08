targetScope = 'resourceGroup'

@description('Region for state storage and the backend managed identity.')
param location string

@description('Globally unique name of the dedicated storage account.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Name of the private Terraform state container.')
@minLength(3)
@maxLength(63)
param containerName string

@description('Name of the dedicated backend user-assigned managed identity.')
@minLength(3)
@maxLength(128)
param backendIdentityName string

@description('Stable GitHub repository owner ID in the exact OIDC subject.')
@minLength(1)
param githubRepositoryOwnerId string

@description('Stable GitHub repository ID in the exact OIDC subject.')
@minLength(1)
param githubRepositoryId string

@description('Retention in days for soft-deleted blobs and containers.')
@minValue(7)
@maxValue(365)
param softDeleteRetentionDays int

@description('Whether to create a CanNotDelete management lock on the storage account.')
param enableDeleteLock bool

@description('Tags applied to the storage account and backend identity.')
param tags object

var githubSubject = 'repository_owner_id:${githubRepositoryOwnerId}:repository_id:${githubRepositoryId}:environment:avm'
var blobDataContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
)

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_ZRS'
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    dnsEndpointType: 'Standard'
    isHnsEnabled: false
    isLocalUserEnabled: false
    isNfsV3Enabled: false
    isSftpEnabled: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Allow'
    }
    encryption: {
      keySource: 'Microsoft.Storage'
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    isVersioningEnabled: true
    deleteRetentionPolicy: {
      enabled: true
      days: softDeleteRetentionDays
      allowPermanentDelete: false
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: softDeleteRetentionDays
    }
  }
}

resource stateContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

resource backendIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: backendIdentityName
  location: location
  tags: tags
}

resource githubFederation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: backendIdentity
  name: 'github-avm'
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    subject: githubSubject
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}

resource backendStateAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: stateContainer
  name: guid(stateContainer.id, backendIdentity.id, blobDataContributorRoleId)
  properties: {
    principalId: backendIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: blobDataContributorRoleId
    description: 'Repository-sync backend access to this Terraform state container only.'
  }
}

resource storageDeleteLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
  scope: storageAccount
  name: 'protect-state-storage'
  properties: {
    level: 'CanNotDelete'
    notes: 'Protects state infrastructure from ARM deletion, not blob data deletion. Remove only after an approved recovery or retirement plan.'
  }
}

output backendClientId string = backendIdentity.properties.clientId
output backendTenantId string = backendIdentity.properties.tenantId
output backendIdentityId string = backendIdentity.id
output storageAccountId string = storageAccount.id
output stateContainerId string = stateContainer.id
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob
output federatedSubject string = githubSubject
