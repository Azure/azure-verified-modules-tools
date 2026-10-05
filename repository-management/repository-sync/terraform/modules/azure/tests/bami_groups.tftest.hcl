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
  target = data.azuread_client_config.current
  values = {
    tenant_id = "10000000-0000-4000-8000-000000000001"
    client_id = "10000000-0000-4000-8000-000000000002"
    object_id = "10000000-0000-4000-8000-000000000011"
  }
}

override_data {
  target = data.azuread_group.test_permissions["repository-readers"]
  values = {
    object_id        = "10000000-0000-4000-8000-000000000008"
    display_name     = "repository-readers"
    security_enabled = true
    types            = []
  }
}

override_data {
  target = data.azuread_group.test_permissions["repository-owners"]
  values = {
    object_id        = "10000000-0000-4000-8000-000000000009"
    display_name     = "repository-owners"
    security_enabled = true
    types            = []
  }
}

override_data {
  target = data.azuread_group.test_permissions["analytics-admins"]
  values = {
    object_id        = "10000000-0000-4000-8000-000000000010"
    display_name     = "analytics-admins"
    security_enabled = true
    types            = []
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
  entra_group_names                   = ["repository-readers", "repository-owners"]
  expected_identity_context = {
    tenant_id            = "10000000-0000-4000-8000-000000000001"
    subscription_id      = "10000000-0000-4000-8000-000000000003"
    controller_client_id = "10000000-0000-4000-8000-000000000002"
    bicep_client_id      = "10000000-0000-4000-8000-000000000004"
  }
}

run "configured_names_create_only_individual_group_edges" {
  command = plan

  assert {
    condition = (
      toset(keys(azuread_group_member.test_permissions)) == var.entra_group_names &&
      alltrue([for name, membership in azuread_group_member.test_permissions :
        membership.group_object_id == data.azuread_group.test_permissions[name].object_id &&
        membership.member_object_id == azapi_resource.identity.output.properties.principalId
      ])
    )
    error_message = "Configured names must create only this repository's resolved membership edges, never a direct BAMI Owner assignment."
  }

  assert {
    condition = (
      output.test_group_contract.azure_context.tenant_id == var.expected_identity_context.tenant_id &&
      output.test_group_contract.graph_context.client_id == var.expected_identity_context.controller_client_id &&
      length(keys(output.test_group_contract.groups)) == 2 &&
      alltrue([for group in output.test_group_contract.groups : length(keys(group)) == 3])
    )
    error_message = "Observed evidence must contain only provider identifiers and allow-listed group metadata."
  }
}

run "additional_configured_name_accumulates_an_edge" {
  command = plan

  variables {
    entra_group_names = ["repository-readers", "repository-owners", "analytics-admins"]
  }

  assert {
    condition = (
      length(azuread_group_member.test_permissions) == 3 &&
      azuread_group_member.test_permissions["analytics-admins"].group_object_id == "10000000-0000-4000-8000-000000000010"
    )
    error_message = "An additional configured name must not replace default memberships."
  }
}

run "recreated_group_uses_its_new_resolved_object_id" {
  command = plan

  override_data {
    target = data.azuread_group.test_permissions["repository-readers"]
    values = {
      object_id        = "90000000-0000-4000-8000-000000000008"
      display_name     = "repository-readers"
      security_enabled = true
      types            = []
    }
  }

  assert {
    condition     = azuread_group_member.test_permissions["repository-readers"].group_object_id == "90000000-0000-4000-8000-000000000008"
    error_message = "Membership must follow the current target-tenant lookup, not a pinned historical ID."
  }
}

run "wrong_graph_tenant_is_rejected_before_membership" {
  command = plan

  override_data {
    target = data.azuread_client_config.current
    values = {
      tenant_id = "90000000-0000-4000-8000-000000000001"
      client_id = "10000000-0000-4000-8000-000000000002"
      object_id = "10000000-0000-4000-8000-000000000011"
    }
  }

  expect_failures = [data.azuread_client_config.current]
}

run "wrong_azure_subscription_is_rejected_before_membership" {
  command = plan

  override_data {
    target = data.azapi_client_config.current
    values = {
      tenant_id       = "10000000-0000-4000-8000-000000000001"
      subscription_id = "90000000-0000-4000-8000-000000000003"
    }
  }

  expect_failures = [data.azapi_client_config.current]
}

run "lookup_uses_the_configured_name" {
  command = plan

  assert {
    condition     = data.azuread_group.test_permissions["repository-owners"].display_name == "repository-owners"
    error_message = "Group lookups must use the exact configured display name."
  }
}

run "directory_dynamic_membership_is_not_manually_managed" {
  command = plan

  override_data {
    target = data.azuread_group.test_permissions["repository-owners"]
    values = {
      object_id        = "10000000-0000-4000-8000-000000000009"
      display_name     = "repository-owners"
      security_enabled = true
      types            = ["DynamicMembership"]
    }
  }

  expect_failures = [data.azuread_group.test_permissions]
}

run "controller_cannot_receive_repository_group_edges" {
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

  expect_failures = [azuread_group_member.test_permissions, output.client_id]
}

run "shared_bicep_client_is_rejected_even_without_group_edges" {
  command = plan

  variables {
    entra_group_names = []
  }

  override_resource {
    target          = azapi_resource.identity
    override_during = plan
    values = {
      id = "/subscriptions/10000000-0000-4000-8000-000000000003/resourceGroups/rg-bami-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/Azure-terraform-azurerm-avm-ptn-example-repo"
      output = {
        properties = {
          principalId = "10000000-0000-4000-8000-000000000007"
          clientId    = "10000000-0000-4000-8000-000000000004"
          tenantId    = "10000000-0000-4000-8000-000000000001"
        }
      }
    }
  }

  expect_failures = [output.client_id]
}
