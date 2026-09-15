mock_provider "azapi" {}
mock_provider "modtm" {}
mock_provider "random" {}

variables {
  location = "eastus"
}

run "apply" {
  command = apply

  module {
    source = "./tests/wrapper"
  }

  variables {
    create_example_resources = true
  }

  assert {
    condition     = module.test.example_resource_counts.telemetry == 1
    error_message = "Telemetry resource should be created when enable_telemetry is true (default)."
  }

  assert {
    condition     = module.test.example_resource_counts.resource_groups == 2
    error_message = "Two example resource groups should be created when create_example_resources is true."
  }

  assert {
    condition     = module.test.example_resource_counts.singleton_resource_groups == 1
    error_message = "One singleton example resource group should be created when create_example_resources is true."
  }

  assert {
    condition     = module.test.resource_ids == module.test.example_resource_ids && length(module.test.resource_ids) == 2
    error_message = "The deprecated resource_ids output must preserve the current output's two resource IDs."
  }
}

run "current_interface" {
  command = plan

  module {
    source = "./tests/wrapper"
  }

  variables {
    create_mock_resources = true
  }

  assert {
    condition     = module.test.example_resource_counts.resource_groups == 2 && module.test.example_resource_counts.singleton_resource_groups == 1
    error_message = "The current creation input must enable both resource shapes."
  }
}

run "safe_defaults" {
  command = plan

  module {
    source = "./tests/wrapper"
  }

  assert {
    condition     = module.test.example_resource_counts.resource_groups == 0 && module.test.example_resource_counts.singleton_resource_groups == 0
    error_message = "Neither creation input may enable Azure resources by default."
  }
}

run "telemetry_disabled" {
  command = plan

  module {
    source = "./tests/wrapper"
  }

  variables {
    enable_telemetry = false
  }

  assert {
    condition     = module.test.example_resource_counts.telemetry == 0
    error_message = "Telemetry must remain disabled when enable_telemetry is false."
  }
}
