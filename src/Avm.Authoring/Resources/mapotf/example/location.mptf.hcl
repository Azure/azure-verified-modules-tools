data "variable" "example_location" {
  name = "location"
}

data "variable" "example_telemetry_location" {
  name = "telemetry_location"
}

locals {
  example_location_modules = {
    for name, source in try(data.module_source.example_telemetry, {}) : name => data.module.example_telemetry.result[name]
    if contains(keys(source.variables), "location")
  }
  example_missing_location_calls = {
    for name, call in local.example_location_modules : name => call
    if !contains(keys(call), "location")
  }
  example_legacy_location_calls = {
    for name, call in data.module.example_telemetry.result : name => call
    if contains(keys(call), "telemetry_location")
  }
  example_location_required = length(local.example_missing_location_calls) > 0
  example_location_exists   = length(data.variable.example_location.result) == 1
  example_telemetry_location_exists = length(data.variable.example_telemetry_location.result) == 1
}

transform "remove_block" "example_telemetry_location" {
  for_each             = local.example_telemetry_location_exists ? toset([1]) : toset([])
  target_block_address = "variable.telemetry_location"
}

transform "new_block" "example_location" {
  for_each       = local.example_location_required && !local.example_location_exists ? toset([1]) : toset([])
  new_block_type = "variable"
  labels         = ["location"]
  filename       = "variables.tf"
  asraw {
    type        = string
    description = "The Azure region for this module's resources or telemetry deployment."
    nullable    = false
  }
}

transform "reorder_attributes" "expand_inline_location_calls" {
  for_each = {
    for name, call in data.module.example_telemetry.result : name => call
    if (contains(keys(local.example_location_modules), name) || contains(keys(local.example_legacy_location_calls), name)) && !contains(keys(local.example_telemetry_modules), name) && call.mptf.range.start_line == call.mptf.range.end_line
  }
  target_block_address     = "module.${each.key}"
  sort_body_alphabetically = false
}

transform "update_in_place" "forward_example_location" {
  for_each             = local.example_missing_location_calls
  target_block_address = "module.${each.key}"
  asraw {
    location = var.location
  }
  depends_on = [
    transform.new_block.example_location,
    transform.reorder_attributes.expand_inline_location_calls,
    transform.reorder_attributes.expand_example_telemetry_modules,
  ]
}

transform "remove_block_element" "legacy_example_telemetry_location" {
  for_each             = local.example_legacy_location_calls
  target_block_address = "module.${each.key}"
  paths                = ["telemetry_location"]
  depends_on = [
    transform.update_in_place.forward_example_location,
    transform.reorder_attributes.expand_inline_location_calls,
    transform.reorder_attributes.expand_example_telemetry_modules,
  ]
}
