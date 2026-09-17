data "module" "example_telemetry" {}

data "module_source" "example_telemetry" {
  for_each = {
    for name, call in data.module.example_telemetry.result : name => call
    if try(trimspace(call.enable_telemetry) != "false", true)
  }
  source  = each.value.source
  version = try(each.value.version, "")
}

locals {
  example_telemetry_modules = {
    for name, source in try(data.module_source.example_telemetry, {}) : name => data.module.example_telemetry.result[name]
    if contains(keys(source.variables), "enable_telemetry")
  }
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
    enable_telemetry = false
  }
  depends_on = [
    transform.reorder_attributes.expand_example_telemetry_modules,
  ]
}
