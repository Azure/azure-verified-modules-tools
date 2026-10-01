mock_provider "azapi" {}
mock_provider "azuread" {}

override_data {
  target = data.azapi_client_config.current
  values = {
    tenant_id       = "10000000-0000-4000-8000-000000000001"
    subscription_id = "10000000-0000-4000-8000-000000000003"
  }
}

override_data {
  target = data.azuread_client_config.bami[0]
  values = {
    tenant_id = "10000000-0000-4000-8000-000000000001"
    client_id = "10000000-0000-4000-8000-000000000002"
    object_id = "10000000-0000-4000-8000-000000000011"
  }
}

override_data {
  target = data.azuread_group.entra_readers
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
  target = data.azuread_group.test_permissions["test_identity_owners"]
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
  target = data.azuread_group.test_permissions["fabric_admins"]
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
  target          = azapi_resource.identity
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
  management_group_id                 = "mg-bami-test"
  identity_resource_group_name        = "rg-bami-test"
  github_repository_owner             = "Azure"
  github_repository_name              = "terraform-azurerm-avm-ptn-example-repo"
  github_repository_environment_names = ["pr-check", "integration-test", "examples-test"]
  location                            = "eastus2"
  is_protected_repo                   = true
  github_job_workflow_ref             = "Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@refs/heads/main"
  github_organization_id              = "6844498"
  github_repository_id                = "1234"
  repository_sync_repository_id       = "1239632211"
  bami_group_settings = {
    tenant_id                     = "10000000-0000-4000-8000-000000000001"
    controller_client_id          = "10000000-0000-4000-8000-000000000002"
    entra_readers_group_id        = "10000000-0000-4000-8000-000000000008"
    test_identity_owners_group_id = "10000000-0000-4000-8000-000000000009"
    fabric_admins_group_id        = "10000000-0000-4000-8000-000000000010"
    fabric_admin_apis             = false
  }
}

run "bami_uses_only_required_individual_group_edges_by_default" {
  command = plan

  assert {
    condition = (
      length(azapi_resource.identity_role_assignment) == 0 &&
      length(azuread_group_member.test_identity_owners) == 1 &&
      length(azuread_group_member.fabric_admins) == 0 &&
      azuread_group_member.example.group_object_id == var.bami_group_settings.entra_readers_group_id &&
      azuread_group_member.test_identity_owners[0].group_object_id == var.bami_group_settings.test_identity_owners_group_id &&
      azuread_group_member.example.member_object_id == azapi_resource.identity.output.properties.principalId &&
      azuread_group_member.test_identity_owners[0].member_object_id == azapi_resource.identity.output.properties.principalId
    )
    error_message = "BAMI must use only the dedicated identity's pinned readers/owners edges; direct Owner and Fabric access are absent."
  }

  assert {
    condition = (
      output.test_group_contract.azure_context.tenant_id == var.bami_group_settings.tenant_id &&
      output.test_group_contract.graph_context.client_id == var.bami_group_settings.controller_client_id &&
      length(keys(output.test_group_contract.groups)) == 3 &&
      alltrue([for group in output.test_group_contract.groups : length(keys(group)) == 6])
    )
    error_message = "Observed evidence must expose only provider identifiers and six allow-listed fields for each group, never members or owners."
  }
}

run "explicit_fabric_opt_in_adds_only_the_dedicated_identity_edge" {
  command = plan

  variables {
    bami_group_settings = {
      tenant_id                     = "10000000-0000-4000-8000-000000000001"
      controller_client_id          = "10000000-0000-4000-8000-000000000002"
      entra_readers_group_id        = "10000000-0000-4000-8000-000000000008"
      test_identity_owners_group_id = "10000000-0000-4000-8000-000000000009"
      fabric_admins_group_id        = "10000000-0000-4000-8000-000000000010"
      fabric_admin_apis             = true
    }
  }

  assert {
    condition = (
      length(azapi_resource.identity_role_assignment) == 0 &&
      length(azuread_group_member.fabric_admins) == 1 &&
      azuread_group_member.fabric_admins[0].group_object_id == var.bami_group_settings.fabric_admins_group_id &&
      azuread_group_member.fabric_admins[0].member_object_id == azapi_resource.identity.output.properties.principalId
    )
    error_message = "Explicit opt-in must add only the dedicated repository identity to the pinned test Fabric group."
  }
}

run "legacy_keeps_direct_owner_and_original_reader_edge" {
  command = plan

  variables {
    bami_group_settings = null
  }

  assert {
    condition = (
      length(azapi_resource.identity_role_assignment) == 1 &&
      length(azuread_group_member.test_identity_owners) == 0 &&
      length(azuread_group_member.fabric_admins) == 0 &&
      local.entra_readers_group_name == "grp-sec-avm-tf-end-to-end-testing-entra-readers" &&
      azapi_resource.identity_role_assignment[0].body.properties.conditionVersion == "2.0" &&
      azapi_resource.identity_role_assignment[0].body.properties.principalId == azapi_resource.identity.output.properties.principalId
    )
    error_message = "Legacy must retain its conditioned direct Owner assignment and original readers membership, without BAMI access edges."
  }
}

run "wrong_graph_tenant_is_rejected_before_membership" {
  command = plan

  override_data {
    target = data.azuread_client_config.bami[0]
    values = {
      tenant_id = "90000000-0000-4000-8000-000000000001"
      client_id = "10000000-0000-4000-8000-000000000002"
      object_id = "10000000-0000-4000-8000-000000000011"
    }
  }

  expect_failures = [data.azuread_client_config.bami]
}

run "wrong_azure_tenant_is_rejected_before_membership" {
  command = plan

  override_data {
    target = data.azapi_client_config.current
    values = {
      tenant_id       = "90000000-0000-4000-8000-000000000001"
      subscription_id = "10000000-0000-4000-8000-000000000003"
    }
  }

  expect_failures = [data.azapi_client_config.current]
}

run "bootstrap_fabric_group_cannot_replace_a_test_group" {
  command = plan

  override_data {
    target = data.azuread_group.test_permissions["fabric_admins"]
    values = {
      object_id               = "10000000-0000-4000-8000-000000000010"
      display_name            = "avm-bootstrap-fabric-admins"
      security_enabled        = true
      mail_enabled            = false
      types                   = []
      onpremises_sync_enabled = null
    }
  }

  expect_failures = [data.azuread_group.test_permissions]
}

run "dynamic_owner_group_is_rejected" {
  command = plan

  override_data {
    target = data.azuread_group.test_permissions["test_identity_owners"]
    values = {
      object_id               = "10000000-0000-4000-8000-000000000009"
      display_name            = "avm-test-identity-owners"
      security_enabled        = true
      mail_enabled            = false
      types                   = ["DynamicMembership"]
      onpremises_sync_enabled = null
    }
  }

  expect_failures = [data.azuread_group.test_permissions]
}

run "controller_cannot_receive_repository_test_group_edges" {
  command = plan

  override_resource {
    target          = azapi_resource.identity
    override_during = plan
    values = {
      id = "/subscriptions/10000000-0000-4000-8000-000000000003/resourceGroups/rg-bami-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/Azure-terraform-azurerm-avm-ptn-example-repo"
      output = {
        properties = {
          principalId = "10000000-0000-4000-8000-000000000011"
          clientId    = "10000000-0000-4000-8000-000000000002"
          tenantId    = "10000000-0000-4000-8000-000000000001"
        }
      }
    }
  }

  expect_failures = [azuread_group_member.example, azuread_group_member.test_identity_owners]
}
