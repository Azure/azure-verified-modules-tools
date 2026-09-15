variables {
  location = "eastus"
}

run "apply" {
  command = apply

  module {
    source = "./tests/wrapper"
  }

  assert {
    condition     = module.test.example_resource_counts.telemetry == 1
    error_message = "Telemetry resource should be created when enable_telemetry is true (default)."
  }

  assert {
    condition     = module.test.example_resource_counts.resource_groups == 0 && module.test.example_resource_counts.singleton_resource_groups == 0
    error_message = "Integration tests must not create Azure example resources with default inputs."
  }
}
