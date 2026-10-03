mock_provider "azurerm" {}
mock_provider "azapi" {
  mock_data "azapi_client_config" {
    defaults = {
      subscription_id          = "00000000-0000-0000-0000-000000000000"
      subscription_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
    }
  }
}
mock_provider "random" {}

variables {
  create_example_resources = true
  location                 = "eastus"
}

run "setup" {
  module {
    source = "./tests/unit/setup"
  }
  providers = {
    azapi = azapi
  }

  assert {
    condition     = output.name_prefix == "avmtest-unit"
    error_message = "The helper module referenced by this run block should be installed by terraform init."
  }
}

run "apply" {
  command = apply

  assert {
    condition     = can(azapi_resource.telemetry)
    error_message = "Telemetry resource should be created when enable_telemetry is true (default)."
  }

  assert {
    condition     = length(azurerm_resource_group.this) == 2
    error_message = "Two example resource groups should be created when create_example_resources is true."
  }

  assert {
    condition     = length(azurerm_management_lock.rg_lock) == 1
    error_message = "One management lock should be created when create_example_resources is true."
  }
}
