mock_provider "azapi" {}
mock_provider "azuread" {}
mock_provider "github" {}

override_data {
  target = module.github.data.github_organization.this
  values = {
    id = "6844498"
  }
}

override_resource {
  target          = module.github.github_repository.this
  override_during = plan
  values = {
    id        = "terraform-azurerm-avm-ptn-example-repo"
    name      = "terraform-azurerm-avm-ptn-example-repo"
    repo_id   = 1234
    full_name = "Azure/terraform-azurerm-avm-ptn-example-repo"
  }
}

override_data {
  target = module.bami[0].data.azapi_client_config.current
  values = {
    tenant_id       = "10000000-0000-4000-8000-000000000001"
    subscription_id = "10000000-0000-4000-8000-000000000003"
    client_id       = "10000000-0000-4000-8000-000000000002"
  }
}

override_data {
  target = module.bami[0].data.azuread_client_config.current
  values = {
    tenant_id = "10000000-0000-4000-8000-000000000001"
    client_id = "10000000-0000-4000-8000-000000000002"
    object_id = "10000000-0000-4000-8000-000000000011"
  }
}

override_data {
  target = module.bami[0].data.azuread_group.test_permissions["avm-test-entra-readers"]
  values = {
    object_id        = "10000000-0000-4000-8000-000000000008"
    display_name     = "avm-test-entra-readers"
    security_enabled = true
    types            = []
  }
}

override_data {
  target = module.bami[0].data.azuread_group.test_permissions["avm-test-identity-owners"]
  values = {
    object_id        = "10000000-0000-4000-8000-000000000009"
    display_name     = "avm-test-identity-owners"
    security_enabled = true
    types            = []
  }
}

override_resource {
  target          = module.bami[0].azapi_resource.identity
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
  entra_group_names             = ["avm-test-entra-readers", "avm-test-identity-owners"]
  github_repository_name        = "terraform-azurerm-avm-ptn-example-repo"
  github_teams                  = {}
  module_id                     = "avm-ptn-example-repo"
  module_name                   = "Example"
  repository_sync_repository_id = "1239632211"
  bami_test_settings = {
    tenant_id                    = "10000000-0000-4000-8000-000000000001"
    management_group_id          = "mg-bami-test"
    identity_resource_group_name = "rg-bami-test"
    controller_client_id         = "10000000-0000-4000-8000-000000000002"
    bicep_client_id              = "10000000-0000-4000-8000-000000000004"
    admin_subscription_id        = "10000000-0000-4000-8000-000000000003"
    persistent_subscription_id   = "10000000-0000-4000-8000-000000000005"
    test_subscription_ids = [for number in range(1, 29) : {
      name = "test-${number}"
      id   = format("00000000-0000-4000-8000-%012d", number)
    }]
  }
}

run "tools_repository_id_is_required" {
  command = plan
  variables {
    repository_sync_repository_id = null
  }
  expect_failures = [var.repository_sync_repository_id]
}

run "tools_repository_id_must_be_positive" {
  command = plan
  variables {
    repository_sync_repository_id = "0"
  }
  expect_failures = [var.repository_sync_repository_id]
}

run "standard_labels_are_read_from_tools_json" {
  command = plan

  assert {
    condition = (
      length(local.labels) == 45 &&
      local.labels["Needs: Module Owner :mega:"].name == "Needs: Module Owner :mega:" &&
      local.labels["Needs: Module Owner :mega:"].color == "FF0019" &&
      local.labels["Needs: Module Owner :mega:"].description == "This module needs an owner to develop or maintain it"
    )
    error_message = "Terraform must use all 45 local JSON labels and preserve the GitHub-safe description."
  }
}

run "normal_sync_requires_verified_bami_settings" {
  command = plan

  variables {
    bami_test_settings = null
  }
  expect_failures = [var.bami_test_settings]
}

run "repository_creation_remains_independent" {
  command = plan

  variables {
    repository_creation_mode_enabled = true
    repository_sync_repository_id    = null
    bami_test_settings               = null
  }
  assert {
    condition     = local.test_settings.client_id == "" && length(local.test_settings.test_subscription_ids) == 0
    error_message = "Repository creation must not provision test identities or publish test settings."
  }
  assert {
    condition = (
      output.test_settings.client_id == "" &&
      output.test_settings.tenant_id == "" &&
      length(output.test_settings.test_subscription_ids) == 0
    )
    error_message = "Repository creation must not expose a usable test identity."
  }
}

run "unified_plan_binds_the_expected_tenant" {
  command = plan

  variables {
    bami_test_settings = {
      tenant_id                    = "10000000-0000-4000-8000-000000000001"
      management_group_id          = "mg-bami-test"
      identity_resource_group_name = "rg-bami-test"
      controller_client_id         = "10000000-0000-4000-8000-000000000002"
      bicep_client_id              = "10000000-0000-4000-8000-000000000004"
      admin_subscription_id        = "10000000-0000-4000-8000-000000000003"
      persistent_subscription_id   = "10000000-0000-4000-8000-000000000005"
      test_subscription_ids = [for number in range(1, 29) : {
        name = "test-${number}"
        id   = format("00000000-0000-4000-8000-%012d", number)
      }]
    }
  }

  assert {
    condition = (
      local.test_settings.client_id == module.bami[0].client_id &&
      local.test_settings.tenant_id == var.bami_test_settings.tenant_id &&
      local.test_settings.test_subscription_ids == var.bami_test_settings.test_subscription_ids
    )
    error_message = "BAMI must replace all three effective settings together."
  }
  assert {
    condition = (
      length(keys(output.test_settings)) == 3 &&
      output.test_settings.client_id == "10000000-0000-4000-8000-000000000006" &&
      output.test_settings.client_id != var.bami_test_settings.controller_client_id &&
      output.test_settings.tenant_id == var.bami_test_settings.tenant_id &&
      output.test_settings.test_subscription_ids == var.bami_test_settings.test_subscription_ids &&
      length(output.test_settings.test_subscription_ids) == 28 &&
      alltrue([for subscription in output.test_settings.test_subscription_ids :
        subscription.id != var.bami_test_settings.admin_subscription_id &&
        subscription.id != var.bami_test_settings.persistent_subscription_id
      ])
    )
    error_message = "The plan must expose the BAMI execution identity and only its 28 ephemeral test subscriptions."
  }
  assert {
    condition = (
      output.test_identity.repository_id == "1234" &&
      output.test_identity.repository_owner_id == "6844498" &&
      output.test_identity.client_id == output.test_settings.client_id
    )
    error_message = "One root must bind GitHub federation and consumer settings to its own repository identity."
  }
}

run "controller_and_shared_bicep_must_differ" {
  command = plan

  variables {
    bami_test_settings = {
      tenant_id                    = "10000000-0000-4000-8000-000000000001"
      management_group_id          = "mg-bami-test"
      identity_resource_group_name = "rg-bami-test"
      controller_client_id         = "10000000-0000-4000-8000-000000000002"
      bicep_client_id              = "10000000-0000-4000-8000-000000000002"
      admin_subscription_id        = "10000000-0000-4000-8000-000000000003"
      persistent_subscription_id   = "10000000-0000-4000-8000-000000000005"
      test_subscription_ids = [for number in range(1, 29) : {
        name = "test-${number}"
        id   = format("00000000-0000-4000-8000-%012d", number)
      }]
    }
  }
  expect_failures = [var.bami_test_settings]
}

run "incomplete_subscription_pool_is_rejected" {
  command = plan

  variables {
    bami_test_settings = {
      tenant_id                    = "10000000-0000-4000-8000-000000000001"
      management_group_id          = "mg-bami-test"
      identity_resource_group_name = "rg-bami-test"
      controller_client_id         = "10000000-0000-4000-8000-000000000002"
      bicep_client_id              = "10000000-0000-4000-8000-000000000004"
      admin_subscription_id        = "10000000-0000-4000-8000-000000000003"
      persistent_subscription_id   = "10000000-0000-4000-8000-000000000005"
      test_subscription_ids        = []
    }
  }
  expect_failures = [var.bami_test_settings]
}

run "persistent_subscription_is_not_disposable" {
  command = plan

  variables {
    bami_test_settings = {
      tenant_id                    = "10000000-0000-4000-8000-000000000001"
      management_group_id          = "mg-bami-test"
      identity_resource_group_name = "rg-bami-test"
      controller_client_id         = "10000000-0000-4000-8000-000000000002"
      bicep_client_id              = "10000000-0000-4000-8000-000000000004"
      admin_subscription_id        = "10000000-0000-4000-8000-000000000003"
      persistent_subscription_id   = "10000000-0000-4000-8000-000000000005"
      test_subscription_ids = [for number in range(1, 29) : {
        name = "test-${number}"
        id   = number == 1 ? "10000000-0000-4000-8000-000000000005" : format("00000000-0000-4000-8000-%012d", number)
      }]
    }
  }
  expect_failures = [var.bami_test_settings]
}

run "administration_subscription_is_not_disposable" {
  command = plan

  variables {
    bami_test_settings = {
      tenant_id                    = "10000000-0000-4000-8000-000000000001"
      management_group_id          = "mg-bami-test"
      identity_resource_group_name = "rg-bami-test"
      controller_client_id         = "10000000-0000-4000-8000-000000000002"
      bicep_client_id              = "10000000-0000-4000-8000-000000000004"
      admin_subscription_id        = "10000000-0000-4000-8000-000000000003"
      persistent_subscription_id   = "10000000-0000-4000-8000-000000000005"
      test_subscription_ids = [for number in range(1, 29) : {
        name = "test-${number}"
        id   = number == 1 ? "10000000-0000-4000-8000-000000000003" : format("00000000-0000-4000-8000-%012d", number)
      }]
    }
  }
  expect_failures = [var.bami_test_settings]
}

run "administration_and_persistent_subscriptions_must_differ" {
  command = plan

  variables {
    bami_test_settings = {
      tenant_id                    = "10000000-0000-4000-8000-000000000001"
      management_group_id          = "mg-bami-test"
      identity_resource_group_name = "rg-bami-test"
      controller_client_id         = "10000000-0000-4000-8000-000000000002"
      bicep_client_id              = "10000000-0000-4000-8000-000000000004"
      admin_subscription_id        = "10000000-0000-4000-8000-000000000005"
      persistent_subscription_id   = "10000000-0000-4000-8000-000000000005"
      test_subscription_ids = [for number in range(1, 29) : {
        name = "test-${number}"
        id   = format("00000000-0000-4000-8000-%012d", number)
      }]
    }
  }
  expect_failures = [var.bami_test_settings]
}

run "single_apply_populates_identity_and_consumer_settings" {
  command = apply

  assert {
    condition = (
      output.test_identity.client_id == output.test_settings.client_id &&
      output.test_identity.client_id == "10000000-0000-4000-8000-000000000006" &&
      output.test_identity.repository_id == "1234" &&
      length(output.test_group_contract.groups) == 2
    )
    error_message = "A single apply must resolve the identity and GitHub consumer dependencies."
  }
}
