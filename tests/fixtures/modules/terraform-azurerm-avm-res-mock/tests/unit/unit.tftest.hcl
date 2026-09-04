mock_provider "azapi" {}
mock_provider "azurerm" {}
mock_provider "modtm" {}
mock_provider "random" {}

variables {
  create_example_resources = true
  location                 = "eastus"
}

run "setup" {
  module {
    source = "./tests/unit/setup"
  }

  assert {
    condition     = output.name_prefix == "avmtest-unit"
    error_message = "The helper module referenced by this run block should be installed by terraform init."
  }
}

run "apply" {
  command = apply

  assert {
    condition     = can(modtm_telemetry.telemetry)
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
