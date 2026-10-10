locals {
  repository_name = lower(var.github_repository_name)
  owner_repo_name = var.identity_name == null ? "id-test-terraform-${trimprefix(local.repository_name, "terraform-")}" : var.identity_name
  member_is_repository_identity = (
    lower(azapi_resource.identity.output.properties.tenantId) == lower(data.azapi_client_config.current.tenant_id) &&
    lower(azapi_resource.identity.output.properties.clientId) != lower(data.azuread_client_config.current.client_id) &&
    lower(azapi_resource.identity.output.properties.principalId) != lower(data.azuread_client_config.current.object_id) &&
    (var.expected_identity_context.bicep_client_id == null ? true :
      lower(azapi_resource.identity.output.properties.clientId) != lower(var.expected_identity_context.bicep_client_id)
    )
  )
}