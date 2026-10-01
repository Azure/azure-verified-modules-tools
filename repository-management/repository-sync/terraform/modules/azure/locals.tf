locals {
  role_definition_name_owner = "8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
  owner_repo_name            = replace("${var.github_repository_owner}-${var.github_repository_name}", "windows", "w5s")
  entra_readers_group_name   = "grp-sec-avm-tf-end-to-end-testing-entra-readers"
  bami_group_contracts = var.bami_group_settings == null ? {} : {
    test_identity_owners = {
      object_id    = var.bami_group_settings.test_identity_owners_group_id
      display_name = "avm-test-identity-owners"
    }
    fabric_admins = {
      object_id    = var.bami_group_settings.fabric_admins_group_id
      display_name = "avm-test-fabric-admins"
    }
  }
  bami_member_is_repository_identity = var.bami_group_settings == null ? true : (
    lower(azapi_resource.identity.output.properties.tenantId) == lower(var.bami_group_settings.tenant_id) &&
    lower(azapi_resource.identity.output.properties.clientId) != lower(var.bami_group_settings.controller_client_id) &&
    lower(azapi_resource.identity.output.properties.principalId) != lower(data.azuread_client_config.bami[0].object_id)
  )
}