data "resource" "location_usage" {}
data "data" "location_usage" {}
data "ephemeral" "location_usage" {}
data "local" "location_usage" {}
data "output" "location_usage" {}
data "variable" "location_usage" {}

locals {
  location_reference_gap = "([[:space:]]|/[*]([^*]|[*]+[^*/])*[*]+/|//[^\n]*\n|#[^\n]*\n)*"
  location_reference = "(^|[^A-Za-z0-9_])(var${local.location_reference_gap}[.]${local.location_reference_gap}location|var${local.location_reference_gap}\\[${local.location_reference_gap}\"location\"${local.location_reference_gap}\\]|local${local.location_reference_gap}[.]${local.location_reference_gap}main_location)([^A-Za-z0-9_]|$)"
  location_telemetry_resource = try(data.resource.location_usage.result.azapi_resource.telemetry, null)
  location_has_telemetry = try(
    local.location_telemetry_resource.type == "Microsoft.Resources/deployments@2025-04-01" &&
    trimspace(local.location_telemetry_resource.count) == "var.enable_telemetry ? 1 : 0" &&
    trimspace(local.location_telemetry_resource.location) == "local.main_location",
    false
  )
  location_optional_children = toset([
    for name, source in try(data.module_source.local_calls, {}) : name
    if contains(keys(source.variables), "enable_telemetry") &&
    !try(source.variables.location.required, true) &&
    try(source.variables.location.default == null || source.variables.location.default == "null", false)
  ])
  location_required_children = [
    for name, call in local.missing_location_calls : name
    if !contains(local.location_optional_children, name)
  ]
  location_business_expressions = jsonencode([
    {
      for resource_type, resources in data.resource.location_usage.result : resource_type => {
        for name, resource in resources : name => resource
        if !(local.location_has_telemetry && resource_type == "azapi_resource" && name == "telemetry")
      }
    },
    data.data.location_usage.result,
    data.ephemeral.location_usage.result,
    {
      for name, expression in data.local.location_usage.result : name => expression
      if !(local.location_has_telemetry && name == "main_location" && trimspace(expression) == "var.location")
    },
    data.output.location_usage.result,
    {
      for name, declaration in data.variable.location_usage.result : name => declaration
      if name != "location"
    },
    {
      for name, call in data.module.local_calls.result : name => {
        for attribute, expression in call : attribute => expression
        if !(attribute == "location" && contains(local.location_optional_children, name) && try(trimspace(expression) == "var.location", false))
      }
    },
  ])
  location_business_source = replace(replace(replace(replace(local.location_business_expressions, "\\n", "\n"), "\\r", "\r"), "\\t", "\t"), "\\\"", "\"")
  location_source_files = {
    for filename in fileset(".", "*.tf") : filename => file(filename)
  }
  location_owned_removal = "(?m)^[[:space:]]*removed[[:space:]]*\\{[[:space:]]*from[[:space:]]*=[[:space:]]*(modtm_telemetry[.]telemetry|random_uuid[.]telemetry|azurerm_resource_group_template_deployment[.]telemetry|random_id[.]telem)[[:space:]]+lifecycle[[:space:]]*\\{[[:space:]]*destroy[[:space:]]*=[[:space:]]*false[[:space:]]*\\}[[:space:]]*\\}"
  location_uninspected_blocks = length(fileset(".", "*.tf.json")) > 0 || anytrue([
    for filename, source in local.location_source_files :
    length(regexall("(?m)^[[:space:]]*(provider|check|import|action|list)[[:space:]\"]", source)) > 0 ||
    length(regexall("(?m)^[[:space:]]*removed[[:space:]]*\\{", source)) != length(regexall(local.location_owned_removal, source))
  ])
  location_business_required = (
    length(local.location_required_children) > 0 ||
    length(regexall(local.location_reference, local.location_business_source)) > 0 ||
    local.location_uninspected_blocks
  )
  location_telemetry_contract = !var.test_wrapper && (local.location_has_telemetry || length(local.telemetry_calls) > 0)
  location_telemetry_optional = local.location_telemetry_contract && !local.location_business_required
  location_has_telemetry_validation = anytrue([
    for validation in try(data.variable.location.result.location.validation, []) :
    replace(validation.condition, "/[[:space:]]/", "") == "!var.enable_telemetry||var.location!=null"
  ])
}

transform "reorder_attributes" "expand_telemetry_location" {
  for_each = local.location_telemetry_optional && length(data.variable.location.result) == 1 && try(
    data.variable.location.result.location.mptf.range.start_line == data.variable.location.result.location.mptf.range.end_line,
    false
  ) ? toset([1]) : toset([])
  target_block_address     = "variable.location"
  sort_body_alphabetically = false
}

transform "update_in_place" "optional_telemetry_location" {
  for_each = local.location_telemetry_optional && try(data.variable.location.result.location.type == "string", false) ? toset([1]) : toset([])
  target_block_address = "variable.location"
  asraw {
    default = null
  }
  depends_on = [transform.reorder_attributes.expand_telemetry_location]
}

transform "remove_block_element" "optional_telemetry_location_nullable" {
  for_each = local.location_telemetry_optional && try(data.variable.location.result.location.type == "string", false) ? toset([1]) : toset([])
  target_block_address = "variable.location"
  paths                = ["nullable"]
  depends_on = [transform.update_in_place.optional_telemetry_location]
}

transform "append_block_body" "telemetry_location_validation" {
  for_each = local.location_telemetry_optional && try(data.variable.location.result.location.type == "string", false) && !local.location_has_telemetry_validation ? toset([1]) : toset([])
  target_block_address = "variable.location"
  block_body = <<-BODY
    validation {
      condition     = !var.enable_telemetry || var.location != null
      error_message = "The location must not be null when telemetry is enabled."
    }
  BODY
  depends_on = [transform.remove_block_element.optional_telemetry_location_nullable]
}

transform "remove_block_element" "required_business_location_default" {
  for_each = local.location_telemetry_contract && local.location_business_required && local.location_has_telemetry_validation && try(
    contains(keys(data.variable.location.result.location), "default") && data.variable.location.result.location.default == null,
    false
  ) ? toset([1]) : toset([])
  target_block_address = "variable.location"
  paths                = ["default"]
}

transform "update_in_place" "required_business_location" {
  for_each = local.location_telemetry_contract && local.location_business_required && local.location_has_telemetry_validation && try(
    contains(keys(data.variable.location.result.location), "default") && data.variable.location.result.location.default == null,
    false
  ) ? toset([1]) : toset([])
  target_block_address = "variable.location"
  asraw {
    nullable = false
  }
  depends_on = [transform.remove_block_element.required_business_location_default]
}
