mock_provider "azapi" {}
mock_provider "azuread" {}
mock_provider "github" {}

override_module {
  target = module.azure[0]
  outputs = {
    client_id            = "20000000-0000-4000-8000-000000000001"
    tenant_id            = "20000000-0000-4000-8000-000000000002"
    identity_resource_id = "/subscriptions/20000000-0000-4000-8000-000000000003/resourceGroups/legacy/providers/Microsoft.ManagedIdentity/userAssignedIdentities/legacy"
  }
}

override_data {
  target = module.github.data.github_organization.this
  values = {
    id = "6844498"
  }
}

override_resource {
  target = module.github.github_repository.this
  values = {
    id      = "terraform-azurerm-avm-ptn-example-repo"
    name    = "terraform-azurerm-avm-ptn-example-repo"
    repo_id = 1234
  }
}

variables {
  management_group_id          = "legacy"
  identity_resource_group_name = "legacy"
  github_repository_name       = "terraform-azurerm-avm-ptn-example-repo"
  github_teams                 = {}
  module_id                    = "avm-ptn-example-repo"
  module_name                  = "Example"
  github_labels_source_path    = "tests/labels.csv"
  test_subscription_ids = [{
    name = "legacy"
    id   = "20000000-0000-4000-8000-000000000003"
  }]
}

run "legacy_is_unchanged" {
  command = plan

  assert {
    condition     = local.test_settings.client_id == module.azure[0].client_id && local.test_settings.tenant_id == module.azure[0].tenant_id
    error_message = "Legacy must retain its existing Azure identity."
  }
  assert {
    condition     = local.test_settings.test_subscription_ids == var.test_subscription_ids
    error_message = "Legacy subscriptions must be unchanged."
  }
}

run "repository_creation_remains_independent" {
  command = plan

  variables {
    repository_creation_mode_enabled = true
  }
  assert {
    condition     = length(module.azure) == 0 && local.test_settings.client_id == "" && length(local.test_settings.test_subscription_ids) == 0
    error_message = "Repository creation must not provision test identities or publish test settings."
  }
}

run "bami_uses_complete_tuple_and_retains_legacy_identity" {
  command = plan

  variables {
    bami_test_settings = {
      tenant_id                  = "10000000-0000-4000-8000-000000000001"
      client_id                  = "10000000-0000-4000-8000-000000000006"
      controller_client_id       = "10000000-0000-4000-8000-000000000002"
      bicep_client_id            = "10000000-0000-4000-8000-000000000004"
      admin_subscription_id      = "10000000-0000-4000-8000-000000000003"
      persistent_subscription_id = "10000000-0000-4000-8000-000000000005"
      test_subscription_ids = [for number in range(1, 29) : {
        name = "test-${number}"
        id   = format("00000000-0000-4000-8000-%012d", number)
      }]
    }
  }

  assert {
    condition = (
      local.test_settings.client_id == var.bami_test_settings.client_id &&
      local.test_settings.tenant_id == var.bami_test_settings.tenant_id &&
      local.test_settings.test_subscription_ids == var.bami_test_settings.test_subscription_ids
    )
    error_message = "BAMI must replace all three effective settings together."
  }
  assert {
    condition     = length(module.azure) == 1 && module.azure[0].client_id == "20000000-0000-4000-8000-000000000001"
    error_message = "The legacy Azure module must remain in the same root and state."
  }
}

run "controller_cannot_be_test_identity" {
  command = plan

  variables {
    bami_test_settings = {
      tenant_id                  = "10000000-0000-4000-8000-000000000001"
      client_id                  = "10000000-0000-4000-8000-000000000002"
      controller_client_id       = "10000000-0000-4000-8000-000000000002"
      bicep_client_id            = "10000000-0000-4000-8000-000000000004"
      admin_subscription_id      = "10000000-0000-4000-8000-000000000003"
      persistent_subscription_id = "10000000-0000-4000-8000-000000000005"
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
      tenant_id                  = "10000000-0000-4000-8000-000000000001"
      client_id                  = "10000000-0000-4000-8000-000000000006"
      controller_client_id       = "10000000-0000-4000-8000-000000000002"
      bicep_client_id            = "10000000-0000-4000-8000-000000000004"
      admin_subscription_id      = "10000000-0000-4000-8000-000000000003"
      persistent_subscription_id = "10000000-0000-4000-8000-000000000005"
      test_subscription_ids      = []
    }
  }
  expect_failures = [var.bami_test_settings]
}

run "persistent_subscription_is_not_disposable" {
  command = plan

  variables {
    bami_test_settings = {
      tenant_id                  = "10000000-0000-4000-8000-000000000001"
      client_id                  = "10000000-0000-4000-8000-000000000006"
      controller_client_id       = "10000000-0000-4000-8000-000000000002"
      bicep_client_id            = "10000000-0000-4000-8000-000000000004"
      admin_subscription_id      = "10000000-0000-4000-8000-000000000003"
      persistent_subscription_id = "10000000-0000-4000-8000-000000000005"
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
      tenant_id                  = "10000000-0000-4000-8000-000000000001"
      client_id                  = "10000000-0000-4000-8000-000000000006"
      controller_client_id       = "10000000-0000-4000-8000-000000000002"
      bicep_client_id            = "10000000-0000-4000-8000-000000000004"
      admin_subscription_id      = "10000000-0000-4000-8000-000000000003"
      persistent_subscription_id = "10000000-0000-4000-8000-000000000005"
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
      tenant_id                  = "10000000-0000-4000-8000-000000000001"
      client_id                  = "10000000-0000-4000-8000-000000000006"
      controller_client_id       = "10000000-0000-4000-8000-000000000002"
      bicep_client_id            = "10000000-0000-4000-8000-000000000004"
      admin_subscription_id      = "10000000-0000-4000-8000-000000000005"
      persistent_subscription_id = "10000000-0000-4000-8000-000000000005"
      test_subscription_ids = [for number in range(1, 29) : {
        name = "test-${number}"
        id   = format("00000000-0000-4000-8000-%012d", number)
      }]
    }
  }
  expect_failures = [var.bami_test_settings]
}
