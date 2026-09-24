data "variable" "example_telemetry_location" {
  name = "telemetry_location"
}

data "variable" "example_location" {
  name = "location"
}

locals {
  example_location_modules = {
    for name, call in local.example_telemetry_modules : name => call
    if try(contains(keys(data.module_source.example_telemetry[name].variables), "telemetry_location"), false)
  }
  example_location_required = length(local.example_location_modules) > 0
  example_location_exists   = length(data.variable.example_location.result) == 1
  example_telemetry_location_exists = length(data.variable.example_telemetry_location.result) == 1
}

transform "new_block" "new_example_telemetry_location_with_location" {
  for_each       = local.example_location_required && !local.example_telemetry_location_exists && local.example_location_exists ? toset([1]) : toset([])
  new_block_type = "variable"
  labels         = ["telemetry_location"]
  filename       = "variables.tf"
  asraw {
    type        = string
    default     = null
    description = "Optional. Location for subscription-scoped AVM telemetry. Defaults to this example's location; override it for another region or cloud."
  }
}

transform "new_block" "new_example_telemetry_location_without_location" {
  for_each       = local.example_location_required && !local.example_telemetry_location_exists && !local.example_location_exists ? toset([1]) : toset([])
  new_block_type = "variable"
  labels         = ["telemetry_location"]
  filename       = "variables.tf"
  asraw {
    type        = string
    default     = "westus2"
    description = "Optional. Location for subscription-scoped AVM telemetry. Defaults to westus2; override it for another region or cloud."
    nullable    = false
  }
}

transform "update_in_place" "example_telemetry_location_with_location" {
  for_each             = local.example_location_required && local.example_telemetry_location_exists && local.example_location_exists ? toset([1]) : toset([])
  target_block_address = "variable.telemetry_location"
  asraw {
    type    = string
    default = null
  }
}

transform "remove_block_element" "example_telemetry_location_nullable" {
  for_each             = local.example_location_required && local.example_telemetry_location_exists && local.example_location_exists && try(data.variable.example_telemetry_location.result["telemetry_location"].nullable, null) == false ? toset([1]) : toset([])
  target_block_address = "variable.telemetry_location"
  paths                = ["nullable"]
  depends_on           = [transform.update_in_place.example_telemetry_location_with_location]
}

transform "update_in_place" "example_telemetry_location_without_location" {
  for_each             = local.example_location_required && local.example_telemetry_location_exists && !local.example_location_exists ? toset([1]) : toset([])
  target_block_address = "variable.telemetry_location"
  asraw {
    type     = string
    default  = "westus2"
    nullable = false
  }
}

transform "update_in_place" "forward_example_telemetry_location_with_location" {
  for_each             = local.example_location_exists ? local.example_location_modules : {}
  target_block_address = "module.${each.key}"
  asraw {
    telemetry_location = var.telemetry_location != null ? var.telemetry_location : var.location
  }
  depends_on = [
    transform.new_block.new_example_telemetry_location_with_location,
    transform.update_in_place.example_telemetry_location_with_location,
    transform.reorder_attributes.expand_example_telemetry_modules,
  ]
}

transform "update_in_place" "forward_example_telemetry_location_without_location" {
  for_each             = !local.example_location_exists ? local.example_location_modules : {}
  target_block_address = "module.${each.key}"
  asraw {
    telemetry_location = var.telemetry_location
  }
  depends_on = [
    transform.new_block.new_example_telemetry_location_without_location,
    transform.update_in_place.example_telemetry_location_without_location,
    transform.reorder_attributes.expand_example_telemetry_modules,
  ]
}
