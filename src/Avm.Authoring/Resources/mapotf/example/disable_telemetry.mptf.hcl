data "module" "example_telemetry" {}

data "module_source" "example_telemetry" {
  for_each = data.module.example_telemetry.result
  source   = each.value.source
  version  = try(each.value.version, "")
}

data "variable" "example_telemetry" {
  name = "enable_telemetry"
}

locals {
  example_telemetry_modules = {
    for name, source in try(data.module_source.example_telemetry, {}) : name => data.module.example_telemetry.result[name]
    if contains(keys(source.variables), "enable_telemetry")
  }
  example_telemetry_variables_to_update = {
    for name, variable in data.variable.example_telemetry.result : name => variable
    if name == "enable_telemetry" && length(local.example_telemetry_modules) > 0 && try(variable.default != true, true)
  }
}

transform "new_block" "new_example_telemetry_variable" {
  for_each       = length(local.example_telemetry_modules) > 0 && !contains(keys(data.variable.example_telemetry.result), "enable_telemetry") ? toset([1]) : toset([])
  new_block_type = "variable"
  labels         = ["enable_telemetry"]
  filename       = "variables.tf"
  asraw {
    type        = bool
    default     = true
    description = <<DESCRIPTION
This variable controls whether or not telemetry is enabled for the module.
For more information see <https://aka.ms/avm/telemetryinfo>.
If it is set to false, then no telemetry will be collected.
DESCRIPTION
  }
}

transform "reorder_attributes" "expand_example_telemetry_variables" {
  for_each = {
    for name, variable in local.example_telemetry_variables_to_update : name => variable
    if variable.mptf.range.start_line == variable.mptf.range.end_line && !contains(keys(variable), "default")
  }
  target_block_address     = "variable.${each.key}"
  sort_body_alphabetically = false
}

transform "update_in_place" "default_example_telemetry_variable" {
  for_each             = local.example_telemetry_variables_to_update
  target_block_address = "variable.${each.key}"
  # Scalar merge mode can update an existing inline argument without expanding it.
  merge_object_attributes = each.value.mptf.range.start_line == each.value.mptf.range.end_line && contains(keys(each.value), "default")
  asraw {
    default = true
  }
  depends_on = [
    transform.reorder_attributes.expand_example_telemetry_variables,
  ]
}

transform "reorder_attributes" "expand_example_telemetry_modules" {
  for_each = {
    for name, call in local.example_telemetry_modules : name => call
    if call.mptf.range.start_line == call.mptf.range.end_line
  }
  target_block_address     = "module.${each.key}"
  sort_body_alphabetically = false
}

transform "update_in_place" "disable_example_telemetry" {
  for_each             = local.example_telemetry_modules
  target_block_address = "module.${each.key}"
  asraw {
    enable_telemetry = var.enable_telemetry
  }
  depends_on = [
    transform.new_block.new_example_telemetry_variable,
    transform.update_in_place.default_example_telemetry_variable,
    transform.reorder_attributes.expand_example_telemetry_modules,
  ]
}
