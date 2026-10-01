mock_provider "azapi" {}
mock_provider "azuread" {}

override_data {
  target = module.azure.data.azapi_client_config.current
  values = {
    tenant_id       = "10000000-0000-4000-8000-000000000001"
    subscription_id = "10000000-0000-4000-8000-000000000003"
    client_id       = "10000000-0000-4000-8000-000000000002"
  }
}

override_data {
  target = module.azure.data.azuread_group.entra_readers
  values = {
    object_id               = "10000000-0000-4000-8000-000000000008"
    display_name            = "avm-test-entra-readers"
    security_enabled        = true
    mail_enabled            = false
    types                   = []
    onpremises_sync_enabled = null
  }
}

override_data {
  target = module.azure.data.azuread_client_config.bami[0]
  values = {
    tenant_id = "10000000-0000-4000-8000-000000000001"
    client_id = "10000000-0000-4000-8000-000000000002"
    object_id = "10000000-0000-4000-8000-000000000011"
  }
}

override_data {
  target = module.azure.data.azuread_group.test_permissions["test_identity_owners"]
  values = {
    object_id               = "10000000-0000-4000-8000-000000000009"
    display_name            = "avm-test-identity-owners"
    security_enabled        = true
    mail_enabled            = false
    types                   = []
    onpremises_sync_enabled = null
  }
}

override_data {
  target = module.azure.data.azuread_group.test_permissions["fabric_admins"]
  values = {
    object_id               = "10000000-0000-4000-8000-000000000010"
    display_name            = "avm-test-fabric-admins"
    security_enabled        = true
    mail_enabled            = false
    types                   = []
    onpremises_sync_enabled = null
  }
}

override_resource {
  target          = module.azure.azapi_resource.identity
  override_during = plan
  values = {
    id = "/subscriptions/10000000-0000-4000-8000-000000000003/resourceGroups/rg-bami-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/Azure-terraform-azurerm-avm-ptn-example-repo"
    output = {
      properties = {
        principalId = "10000000-0000-4000-8000-000000000007"
        clientId    = "10000000-0000-4000-8000-000000000006"
        tenantId    = "10000000-0000-4000-8000-000000000001"
      }
    }
  }
}

variables {
  tenant_id                     = "10000000-0000-4000-8000-000000000001"
  controller_client_id          = "10000000-0000-4000-8000-000000000002"
  subscription_id               = "10000000-0000-4000-8000-000000000003"
  management_group_id           = "mg-bami-test"
  identity_resource_group_name  = "rg-bami-test"
  entra_readers_group_id        = "10000000-0000-4000-8000-000000000008"
  test_identity_owners_group_id = "10000000-0000-4000-8000-000000000009"
  fabric_admins_group_id        = "10000000-0000-4000-8000-000000000010"
  github_repository_owner       = "Azure"
  github_repository_name        = "terraform-azurerm-avm-ptn-example-repo"
  github_organization_id        = "6844498"
  github_repository_id          = "1234"
  repository_sync_repository_id = "1239632211"
  github_job_workflow_ref       = "Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@refs/heads/main"
}

run "candidate_rejects_invalid_tools_repository_id" {
  command = plan

  variables {
    repository_sync_repository_id = "0"
  }
  expect_failures = [var.repository_sync_repository_id]
}

run "candidate_rejects_absent_tools_repository_id" {
  command = plan

  variables {
    repository_sync_repository_id = null
  }
  expect_failures = [var.repository_sync_repository_id]
}

run "candidate_plan_binds_the_expected_tenant" {
  command = plan

  assert {
    condition     = output.test_identity.tenant_id == var.tenant_id
    error_message = "The planned candidate must use the selected tenant."
  }
}

run "mocked_candidate_uses_repository_identity_not_controller" {
  command = plan

  assert {
    condition     = output.test_identity.client_id == "10000000-0000-4000-8000-000000000006" && output.test_identity.client_id != var.controller_client_id
    error_message = "The candidate output must be the per-repository identity, never the controller."
  }
  assert {
    condition = (
      output.test_identity.tenant_id == var.tenant_id &&
      output.test_identity.repository_id == var.github_repository_id &&
      output.test_identity.repository_owner_id == var.github_organization_id
    )
    error_message = "Candidate outputs must bind the expected tenant and repository."
  }
}
