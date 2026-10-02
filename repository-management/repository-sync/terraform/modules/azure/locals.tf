locals {
  owner_repo_name = replace("${var.github_repository_owner}-${var.github_repository_name}", "windows", "w5s")
  member_is_repository_identity = (
    lower(azapi_resource.identity.output.properties.tenantId) == lower(data.azapi_client_config.current.tenant_id) &&
    lower(azapi_resource.identity.output.properties.clientId) != lower(data.azuread_client_config.current.client_id) &&
    lower(azapi_resource.identity.output.properties.principalId) != lower(data.azuread_client_config.current.object_id)
  )
}