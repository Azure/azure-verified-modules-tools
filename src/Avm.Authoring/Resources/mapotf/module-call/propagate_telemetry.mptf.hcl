data "module" "telemetry_calls" {}

locals {
  local_telemetry_calls = {
    for name, call in data.module.telemetry_calls.result : name => call
    if try(startswith(call.source, "./") || startswith(call.source, "../"), false)
  }
}

data "module_source" "telemetry_calls" {
  for_each = local.local_telemetry_calls
  source   = each.value.source
  version  = try(each.value.version, "")
}

locals {
  supported_telemetry_calls = {
    for name, source in try(data.module_source.telemetry_calls, {}) : name => data.module.telemetry_calls.result[name]
    if contains(keys(source.variables), "enable_telemetry") && contains(keys(source.variables), "telemetry_location")
  }
}

transform "reorder_attributes" "expand_inline_telemetry_calls" {
  for_each = {
    for name, call in local.supported_telemetry_calls : name => call
    if call.mptf.range.start_line == call.mptf.range.end_line
  }
  target_block_address     = "module.${each.key}"
  sort_body_alphabetically = false
}

transform "update_in_place" "propagate_telemetry" {
  for_each             = local.supported_telemetry_calls
  target_block_address = "module.${each.key}"
  asraw {
    enable_telemetry   = var.enable_telemetry
    telemetry_location = local.main_location
  }
  depends_on = [transform.reorder_attributes.expand_inline_telemetry_calls]
}
