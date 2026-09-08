output "workflowVariables" {
  description = "Non-secret repository-sync workflow inputs to configure in the existing GitHub avm environment after state migration. These are not applied automatically."
  value = {
    ARM_BACKEND_CLIENT_ID               = module.backend_identity.client_id
    ARM_BACKEND_TENANT_ID               = module.backend_identity.tenant_id
    ARM_BACKEND_SUBSCRIPTION_ID         = var.subscription_id
    STORAGE_ACCOUNT_NAME                = module.state_storage.name
    STORAGE_ACCOUNT_RESOURCE_GROUP_NAME = module.state_resource_group.name
    STORAGE_ACCOUNT_CONTAINER_NAME      = module.state_storage.containers["tfstate"].name
  }
}

output "resourceGroupId" {
  description = "Resource ID of the dedicated state resource group."
  value       = module.state_resource_group.resource_id
}

output "storageAccountId" {
  description = "Resource ID of the state storage account."
  value       = module.state_storage.resource_id
}

output "stateContainerId" {
  description = "Resource ID of the private state container and scope of the backend role assignment."
  value       = module.state_storage.containers["tfstate"].id
}

output "backendIdentityId" {
  description = "Resource ID of the dedicated backend managed identity."
  value       = module.backend_identity.resource_id
}

output "blobEndpoint" {
  description = "Public Blob endpoint; anonymous and shared-key access are disabled."
  value       = "https://${module.state_storage.fqdn["blob"]}/"
}

output "federatedSubject" {
  description = "Exact GitHub OIDC subject trusted by the backend identity."
  value       = local.federated_subject
}
