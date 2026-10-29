locals {
  repository_name          = lower(var.github_repository_name)
  owner_repo_name          = var.identity_name == null ? "id-test-terraform-${replace(trimprefix(local.repository_name, "terraform-"), "windows", "w5s")}" : var.identity_name
  dedicated_identity       = var.existing_identity == null
  identity_name            = local.dedicated_identity ? local.owner_repo_name : var.existing_identity.name
  identity_resource_id     = local.dedicated_identity ? azapi_resource.identity[0].id : data.azapi_resource.existing_identity[0].id
  identity_properties      = local.dedicated_identity ? azapi_resource.identity[0].output.properties : data.azapi_resource.existing_identity[0].output.properties
  federation_identity_name = local.dedicated_identity ? local.identity_name : "${local.identity_name}-${var.existing_identity.federation_name_key}"
  member_is_repository_identity = (
    lower(local.identity_properties.tenantId) == lower(data.azapi_client_config.current.tenant_id) &&
    lower(local.identity_properties.clientId) != lower(data.azuread_client_config.current.client_id) &&
    lower(local.identity_properties.principalId) != lower(data.azuread_client_config.current.object_id) &&
    (var.expected_identity_context.bicep_client_id == null ? true :
      lower(local.identity_properties.clientId) != lower(var.expected_identity_context.bicep_client_id)
    )
  )
}