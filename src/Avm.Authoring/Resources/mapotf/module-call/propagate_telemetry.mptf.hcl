data "module" "local_calls" {}

data "variable" "location" {
  name = "location"
}

data "variable" "enable_telemetry" {
  name = "enable_telemetry"
}

locals {
  local_calls = {
    for name, call in data.module.local_calls.result : name => call
    if try(startswith(call.source, "./") || startswith(call.source, "../"), false)
  }
}

data "module_source" "local_calls" {
  for_each = local.local_calls
  source   = each.value.source
  version  = try(each.value.version, "")
}

locals {
  location_calls = {
    for name, source in try(data.module_source.local_calls, {}) : name => local.local_calls[name]
    if contains(keys(source.variables), "location")
  }
  telemetry_calls = {
    for name, source in try(data.module_source.local_calls, {}) : name => local.local_calls[name]
    if contains(keys(source.variables), "location") && contains(keys(source.variables), "enable_telemetry")
  }
  missing_location_calls = {
    for name, call in local.location_calls : name => call
    if !contains(keys(call), "location")
  }
  telemetry_missing_location_calls = {
    for name, call in local.missing_location_calls : name => call
    if contains(keys(local.telemetry_calls), name)
  }
  telemetry_existing_location_calls = {
    for name, call in local.telemetry_calls : name => call
    if !contains(keys(local.missing_location_calls), name)
  }
  location_only_missing_calls = {
    for name, call in local.missing_location_calls : name => call
    if !contains(keys(local.telemetry_calls), name)
  }
  legacy_telemetry_location_calls = {
    for name, call in local.local_calls : name => call
    if contains(keys(call), "telemetry_location")
  }
}

transform "new_block" "parent_location" {
  for_each       = length(local.location_calls) > 0 && length(data.variable.location.result) == 0 ? toset([1]) : toset([])
  new_block_type = "variable"
  labels         = ["location"]
  filename       = "variables.tf"
  asraw {
    type        = string
    description = "The Azure region for this module's resources or telemetry deployment."
    nullable    = false
  }
}

transform "new_block" "parent_enable_telemetry" {
  for_each       = length(local.telemetry_calls) > 0 && length(data.variable.enable_telemetry.result) == 0 ? toset([1]) : toset([])
  new_block_type = "variable"
  labels         = ["enable_telemetry"]
  filename       = "variables.tf"
  asraw {
    type     = bool
    default  = true
    nullable = false
  }
}

transform "reorder_attributes" "expand_inline_calls" {
  for_each = {
    for name, call in local.local_calls : name => call
    if (contains(keys(local.location_calls), name) || contains(keys(local.legacy_telemetry_location_calls), name)) && call.mptf.range.start_line == call.mptf.range.end_line
  }
  target_block_address     = "module.${each.key}"
  sort_body_alphabetically = false
}

transform "update_in_place" "propagate_telemetry_and_location" {
  for_each             = local.telemetry_missing_location_calls
  target_block_address = "module.${each.key}"
  asraw {
    enable_telemetry = var.enable_telemetry
    location         = var.location
  }
  depends_on = [
    transform.new_block.parent_location,
    transform.new_block.parent_enable_telemetry,
    transform.reorder_attributes.expand_inline_calls,
  ]
}

transform "update_in_place" "propagate_telemetry" {
  for_each             = local.telemetry_existing_location_calls
  target_block_address = "module.${each.key}"
  asraw {
    enable_telemetry = var.enable_telemetry
  }
  depends_on = [
    transform.new_block.parent_enable_telemetry,
    transform.reorder_attributes.expand_inline_calls,
  ]
}

transform "update_in_place" "propagate_location" {
  for_each             = local.location_only_missing_calls
  target_block_address = "module.${each.key}"
  asraw {
    location = var.location
  }
  depends_on = [
    transform.new_block.parent_location,
    transform.reorder_attributes.expand_inline_calls,
  ]
}

transform "remove_block_element" "legacy_telemetry_location" {
  for_each             = local.legacy_telemetry_location_calls
  target_block_address = "module.${each.key}"
  paths                = ["telemetry_location"]
  depends_on = [
    transform.update_in_place.propagate_telemetry_and_location,
    transform.update_in_place.propagate_telemetry,
    transform.update_in_place.propagate_location,
    transform.reorder_attributes.expand_inline_calls,
  ]
}
