# Remove retired AVM telemetry headers from a root module or discovered submodule.
transform "regex_replace_expression" unwrap_merged_avm_headers {
  regex       = "(?s)^merge\\((.*),\\s*\\(\\s*var\\.enable_telemetry\\s*\\?\\s*\\{\\s*\"User-Agent\"\\s*:\\s*local\\.avm_azapi_header\\s*\\}\\s*:\\s*\\{\\s*\\}\\s*\\)\\s*\\)$"
  replacement = "$${1}"
}

data "resource" "avm_header_consumers" {}
data "data" "avm_header_consumers" {}
data "module" "avm_header_consumers" {}
data "local" "avm_azapi_header" {
  name = "avm_azapi_header"
}
data "local" "avm_azapi_headers" {
  name = "avm_azapi_headers"
}
data "local" "fork_avm" {
  name = "fork_avm"
}
data "local" "valid_module_source_regex" {
  name = "valid_module_source_regex"
}

locals {
  avm_header_attribute_names = [
    "headers",
    "create_headers",
    "delete_headers",
    "read_headers",
    "update_headers",
  ]
  azapi_resource_blocks = merge([
    for type, blocks in data.resource.avm_header_consumers.result : {
      for name, resource in blocks : resource.mptf.block_address => resource
    } if startswith(type, "azapi_")
  ]...)
  azapi_data_blocks = merge([
    for type, blocks in data.data.avm_header_consumers.result : {
      for name, source in blocks : source.mptf.block_address => source
    } if startswith(type, "azapi_")
  ]...)
  avm_azapi_header_exists          = contains(keys(data.local.avm_azapi_header.result), "avm_azapi_header")
  avm_azapi_headers_exists         = contains(keys(data.local.avm_azapi_headers.result), "avm_azapi_headers")
  fork_avm_exists                  = contains(keys(data.local.fork_avm.result), "fork_avm")
  valid_module_source_regex_exists = contains(keys(data.local.valid_module_source_regex.result), "valid_module_source_regex")
  module_calls                     = data.module.avm_header_consumers.result
}

transform "remove_block_element" resource_headers {
  for_each             = local.azapi_resource_blocks
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

transform "remove_block_element" data_headers {
  for_each             = local.azapi_data_blocks
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

transform "remove_block_element" module_header_arguments {
  for_each             = local.module_calls
  target_block_address = "module.${each.key}"
  paths = [
    for name, value in each.value : name
    if try(strcontains(value, "local.avm_azapi_header"), false)
  ]
}

transform "remove_block" avm_azapi_header {
  for_each             = local.avm_azapi_header_exists ? toset([1]) : toset([])
  target_block_address = "local.avm_azapi_header"
}

transform "remove_block" avm_azapi_headers {
  for_each             = local.avm_azapi_headers_exists ? toset([1]) : toset([])
  target_block_address = "local.avm_azapi_headers"
  depends_on = [
    transform.remove_block.avm_azapi_header,
  ]
}

transform "remove_block" fork_avm {
  for_each             = local.fork_avm_exists ? toset([1]) : toset([])
  target_block_address = "local.fork_avm"
  depends_on = [
    transform.remove_block.avm_azapi_headers,
  ]
}

transform "remove_block" valid_module_source_regex {
  for_each             = local.valid_module_source_regex_exists ? toset([1]) : toset([])
  target_block_address = "local.valid_module_source_regex"
  depends_on = [
    transform.remove_block.fork_avm,
  ]
}