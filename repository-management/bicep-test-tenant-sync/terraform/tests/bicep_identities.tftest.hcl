mock_provider "azapi" {
  mock_data "azapi_client_config" {
    defaults = {
      tenant_id       = "10000000-0000-4000-8000-000000000001"
      subscription_id = "10000000-0000-4000-8000-000000000003"
    }
  }
}

mock_provider "azuread" {
  mock_data "azuread_client_config" {
    defaults = {
      tenant_id = "10000000-0000-4000-8000-000000000001"
      client_id = "10000000-0000-4000-8000-000000000002"
      object_id = "10000000-0000-4000-8000-000000000011"
    }
  }
}

override_data {
  target = module.bicep["avm/res/fabric/capacity"].data.azuread_group.test_permissions["avm-test-entra-readers"]
  values = {
    object_id        = "10000000-0000-4000-8000-000000000008"
    display_name     = "avm-test-entra-readers"
    security_enabled = true
    types            = []
  }
}

override_data {
  target = module.bicep["avm/res/fabric/capacity"].data.azuread_group.test_permissions["avm-test-management-group-owners"]
  values = {
    object_id        = "10000000-0000-4000-8000-000000000009"
    display_name     = "avm-test-management-group-owners"
    security_enabled = true
    types            = []
  }
}

override_data {
  target = module.bicep["avm/res/storage/storage-account"].data.azuread_group.test_permissions["avm-test-entra-readers"]
  values = {
    object_id        = "10000000-0000-4000-8000-000000000008"
    display_name     = "avm-test-entra-readers"
    security_enabled = true
    types            = []
  }
}

override_data {
  target = module.bicep["avm/res/storage/storage-account"].data.azuread_group.test_permissions["avm-test-management-group-owners"]
  values = {
    object_id        = "10000000-0000-4000-8000-000000000009"
    display_name     = "avm-test-management-group-owners"
    security_enabled = true
    types            = []
  }
}

override_data {
  target = module.bicep["avm/res/storage/storage-account"].data.azuread_group.test_permissions["avm-test-management-group-iam-admins"]
  values = {
    object_id        = "10000000-0000-4000-8000-000000000010"
    display_name     = "avm-test-management-group-iam-admins"
    security_enabled = true
    types            = []
  }
}

override_resource {
  target          = module.bicep["avm/res/fabric/capacity"].azapi_resource.identity
  override_during = plan
  values = {
    id = "/subscriptions/10000000-0000-4000-8000-000000000003/resourceGroups/rg-bami-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-avm-bicep-avm-res-fabric-capacity-32f81a9a"
    output = {
      properties = {
        principalId = "10000000-0000-4000-8000-000000000007"
        clientId    = "10000000-0000-4000-8000-000000000006"
        tenantId    = "10000000-0000-4000-8000-000000000001"
      }
    }
  }
}

override_resource {
  target          = module.bicep["avm/res/storage/storage-account"].azapi_resource.identity
  override_during = plan
  values = {
    id = "/subscriptions/10000000-0000-4000-8000-000000000003/resourceGroups/rg-bami-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-avm-bicep-avm-res-storage-storage-account-3ecbb5ba"
    output = {
      properties = {
        principalId = "10000000-0000-4000-8000-000000000017"
        clientId    = "10000000-0000-4000-8000-000000000016"
        tenantId    = "10000000-0000-4000-8000-000000000001"
      }
    }
  }
}

variables {
  modules = {
    "avm/res/fabric/capacity" = ["avm-test-entra-readers", "avm-test-management-group-owners"]
    "avm/res/storage/storage-account" = [
      "avm-test-entra-readers", "avm-test-management-group-owners", "avm-test-management-group-iam-admins"
    ]
  }
  github_repository_id          = "447791597"
  github_organization_id        = "6844498"
  repository_sync_repository_id = "1239632211"
  bami_test_settings = {
    tenant_id                    = "10000000-0000-4000-8000-000000000001"
    controller_client_id         = "10000000-0000-4000-8000-000000000002"
    bicep_client_id              = "10000000-0000-4000-8000-000000000004"
    admin_subscription_id        = "10000000-0000-4000-8000-000000000003"
    identity_resource_group_name = "rg-bami-test"
  }
}

run "module_plan_binds_identities_groups_and_workflows" {
  command = plan

  assert {
    condition = (
      length(output.test_identities) == 2 &&
      output.test_identities["avm/res/fabric/capacity"].client_id != output.test_identities["avm/res/storage/storage-account"].client_id &&
      toset(keys(output.test_group_contract["avm/res/fabric/capacity"].groups)) == var.modules["avm/res/fabric/capacity"] &&
      toset(keys(output.test_group_contract["avm/res/storage/storage-account"].groups)) == var.modules["avm/res/storage/storage-account"]
    )
    error_message = "Each module must have its own identity and exactly its configured additive groups."
  }
}

run "one_apply_returns_the_complete_module_mapping" {
  command = apply

  assert {
    condition = (
      output.test_identities["avm/res/fabric/capacity"].client_id == "10000000-0000-4000-8000-000000000006" &&
      output.test_identities["avm/res/storage/storage-account"].client_id == "10000000-0000-4000-8000-000000000016"
    )
    error_message = "One apply must produce both dedicated client IDs without changing the retained shared identity."
  }
}

run "empty_inventory_is_rejected" {
  command = plan

  variables {
    modules = {}
  }

  expect_failures = [var.modules]
}

run "child_module_inventory_is_rejected" {
  command = plan

  variables {
    modules = { "avm/res/storage/storage-account/blob-service" = [] }
  }

  expect_failures = [var.modules]
}
