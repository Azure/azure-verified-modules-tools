mock_provider "azapi" {
  mock_resource "azapi_resource" {
    defaults = {
      output = {
        properties = {
          principalId = "90000000-0000-4000-8000-000000000099"
          tenantId    = "90000000-0000-4000-8000-000000000099"
          clientId    = "90000000-0000-4000-8000-000000000099"
        }
      }
    }
  }
}
mock_provider "azuread" {}
mock_provider "github" {}

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
  github_repository_name = "terraform-azurerm-avm-ptn-example-repo"
  github_teams           = {}
  module_id              = "avm-ptn-example-repo"
  module_name            = "Example"
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

run "seed_only_disposable_mock_retired_state" {
  command   = apply
  state_key = "retired-fixture"

  module {
    source = "./tests/fixtures/retired-identity"
  }

  override_data {
    target = module.azure[0].data.azapi_client_config.current
    values = {
      tenant_id       = "20000000-0000-4000-8000-000000000001"
      subscription_id = "20000000-0000-4000-8000-000000000003"
    }
  }

  override_data {
    target = module.azure[0].data.azuread_group.entra_readers
    values = {
      object_id = "20000000-0000-4000-8000-000000000007"
    }
  }

  override_resource {
    target = module.azure[0].azapi_resource.identity
    values = {
      id = "/subscriptions/20000000-0000-4000-8000-000000000003/resourceGroups/retired-fixture/providers/Microsoft.ManagedIdentity/userAssignedIdentities/retired-fixture"
      output = {
        properties = {
          principalId = "20000000-0000-4000-8000-000000000006"
          tenantId    = "20000000-0000-4000-8000-000000000001"
          clientId    = "20000000-0000-4000-8000-000000000005"
        }
      }
    }
  }
}

run "forget_only_retired_state_without_refresh" {
  command   = plan
  state_key = "retired-fixture"

  assert {
    condition = (
      output.test_settings.tenant_id == var.bami_test_settings.tenant_id &&
      output.test_settings.client_id == var.bami_test_settings.client_id
    )
    error_message = "Retiring old state must preserve only the current verified BAMI consumer settings."
  }
}
