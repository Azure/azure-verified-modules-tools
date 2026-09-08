targetScope = 'subscription'

@description('Region for the resource group, state storage, and backend identity.')
param location string = 'northeurope'

@description('Name of the dedicated resource group. Use a new group, not an existing BAMI resource group.')
@minLength(1)
@maxLength(90)
param resourceGroupName string = 'rg-avm-repository-sync-state-tme'

@description('Globally unique storage account name: 3-24 lowercase letters or digits. The default is stable for this subscription and resource group.')
@minLength(3)
@maxLength(24)
param storageAccountName string = 'stavmstate${uniqueString(subscription().subscriptionId, resourceGroupName)}'

@description('Name of the private Terraform state container.')
@minLength(3)
@maxLength(63)
param containerName string = 'tfstate'

@description('Name of the dedicated backend user-assigned managed identity.')
@minLength(3)
@maxLength(128)
param backendIdentityName string = 'id-avm-repository-sync-state-tme'

@description('Stable GitHub repository owner ID used in the exact OIDC subject.')
@minLength(1)
param githubRepositoryOwnerId string = '6844498'

@description('Stable GitHub repository ID used in the exact OIDC subject.')
@minLength(1)
param githubRepositoryId string = '1239632211'

@description('Retention in days for soft-deleted blobs and containers. This does not expire previous blob versions.')
@minValue(7)
@maxValue(365)
param softDeleteRetentionDays int = 7

@description('Create a CanNotDelete management lock on state storage. Setting false does not remove an existing lock in an incremental deployment.')
param enableDeleteLock bool = true

@description('Tags applied to the resource group, storage account, and backend identity.')
param tags object = {
  workload: 'avm-repository-sync'
  environment: 'tme'
  managedBy: 'bicep'
}

resource stateResourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module stateBackend './modules/state-backend.bicep' = {
  name: 'state-backend-${uniqueString(deployment().name, resourceGroupName)}'
  scope: stateResourceGroup
  params: {
    location: location
    storageAccountName: storageAccountName
    containerName: containerName
    backendIdentityName: backendIdentityName
    githubRepositoryOwnerId: githubRepositoryOwnerId
    githubRepositoryId: githubRepositoryId
    softDeleteRetentionDays: softDeleteRetentionDays
    enableDeleteLock: enableDeleteLock
    tags: tags
  }
}

@description('Non-secret repository-sync workflow inputs for an operator to configure in the existing GitHub avm environment after state migration. These are not applied automatically.')
output workflowVariables object = {
  ARM_BACKEND_CLIENT_ID: stateBackend.outputs.backendClientId
  ARM_BACKEND_TENANT_ID: stateBackend.outputs.backendTenantId
  ARM_BACKEND_SUBSCRIPTION_ID: subscription().subscriptionId
  STORAGE_ACCOUNT_NAME: storageAccountName
  STORAGE_ACCOUNT_RESOURCE_GROUP_NAME: stateResourceGroup.name
  STORAGE_ACCOUNT_CONTAINER_NAME: containerName
}

@description('Resource ID of the dedicated state resource group.')
output resourceGroupId string = stateResourceGroup.id

@description('Resource ID of the state storage account.')
output storageAccountId string = stateBackend.outputs.storageAccountId

@description('Resource ID of the container and scope of the backend role assignment.')
output stateContainerId string = stateBackend.outputs.stateContainerId

@description('Resource ID of the backend managed identity.')
output backendIdentityId string = stateBackend.outputs.backendIdentityId

@description('Standard public Blob endpoint; anonymous and shared-key access are disabled.')
output blobEndpoint string = stateBackend.outputs.blobEndpoint

@description('Exact GitHub OIDC subject trusted by the backend identity.')
output federatedSubject string = stateBackend.outputs.federatedSubject
