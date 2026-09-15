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
    object_id = "10000000-0000-4000-8000-000000000007"
  }
}

override_resource {
  target = module.azure.azapi_resource.identity
  values = {
    id = "/subscriptions/10000000-0000-4000-8000-000000000003/resourceGroups/rg-bami-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/Azure-terraform-azurerm-avm-ptn-example-repo"
    output = {
      properties = {
        principalId = "10000000-0000-4000-8000-000000000008"
        clientId    = "10000000-0000-4000-8000-000000000006"
        tenantId    = "10000000-0000-4000-8000-000000000001"
      }
    }
  }
}

variables {
  tenant_id                    = "10000000-0000-4000-8000-000000000001"
  controller_client_id         = "10000000-0000-4000-8000-000000000002"
  subscription_id              = "10000000-0000-4000-8000-000000000003"
  management_group_id          = "mg-bami-test"
  identity_resource_group_name = "rg-bami-test"
  github_repository_owner      = "Azure"
  github_repository_name       = "terraform-azurerm-avm-ptn-example-repo"
  github_organization_id       = "6844498"
  github_repository_id         = "1234"
  github_job_workflow_ref      = "Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@refs/heads/main"
}

run "candidate_plan_binds_the_expected_tenant" {
  command = plan

  assert {
    condition     = output.test_identity.tenant_id == var.tenant_id
    error_message = "The planned candidate must use the selected tenant."
  }
}

run "mocked_candidate_uses_repository_identity_not_controller" {
  command = apply

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
