# Remove retired telemetry headers before AzAPI resource bodies are reordered.
transform "regex_replace_expression" unwrap_merged_avm_headers {
  regex       = "(?s)^merge\\((.*),\\s*\\(\\s*var\\.enable_telemetry\\s*\\?\\s*\\{\\s*\"User-Agent\"\\s*:\\s*local\\.avm_azapi_header\\s*\\}\\s*:\\s*\\{\\s*\\}\\s*\\)\\s*\\)$"
  replacement = "$${1}"
}

data "resource" "azapi_data_plane_resource" {
  resource_type = "azapi_data_plane_resource"
}

data "resource" "azapi_resource" {
  resource_type = "azapi_resource"
}

data "resource" "azapi_update_resource" {
  resource_type = "azapi_update_resource"
}

data "module" "avm_header_consumers" {}

locals {
  avm_header_attribute_names = [
    "create_headers",
    "delete_headers",
    "read_headers",
    "update_headers",
  ]
  all_azapi_resources_with_full_headers_map = {
    for resource in concat(
      values(try(data.resource.azapi_data_plane_resource.result["azapi_data_plane_resource"], {})),
      values(try(data.resource.azapi_resource.result["azapi_resource"], {})),
    ) : resource.mptf.block_address => resource
  }
  azapi_update_resources_map = {
    for resource in try(data.resource.azapi_update_resource.result["azapi_update_resource"], []) :
    resource.mptf.block_address => resource
  }
  avm_header_module_calls = {
    for name, module in data.module.avm_header_consumers.result : name => module
    if try(strcontains(module.tracing_tags_header, "local.avm_azapi_header"), false)
  }
}

transform "remove_block_element" full_headers {
  for_each             = local.all_azapi_resources_with_full_headers_map
  target_block_address = each.key
  paths = [
    for name in local.avm_header_attribute_names : name
    if try(
      strcontains(each.value[name], "local.avm_azapi_header") &&
      !startswith(trimspace(each.value[name]), "merge("),
      false
    )
  ]
  depends_on = [
    transform.regex_replace_expression.unwrap_merged_avm_headers,
  ]
}

transform "remove_block_element" azapi_update_resource_headers {
  for_each             = local.azapi_update_resources_map
  target_block_address = each.key
  paths = [
    for name in ["read_headers", "update_headers"] : name
    if try(
      strcontains(each.value[name], "local.avm_azapi_header") &&
      !startswith(trimspace(each.value[name]), "merge("),
      false
    )
  ]
  depends_on = [
    transform.regex_replace_expression.unwrap_merged_avm_headers,
  ]
}

transform "remove_block_element" module_tracing_tags_header {
  for_each             = local.avm_header_module_calls
  target_block_address = "module.${each.key}"
  paths                = ["tracing_tags_header"]
}