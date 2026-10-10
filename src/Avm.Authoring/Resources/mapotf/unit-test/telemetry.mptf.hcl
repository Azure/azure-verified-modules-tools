variable "telemetry_subscription_resource_id" {
  type    = string
  default = null
}

variable "provider_mock_bindings" {
  type    = map(set(string))
  default = {}
}

locals {
  telemetry_mock_updates = {
    for name, mock in local.test_file.mock_providers : name => mock
    if (
      name == "azapi" &&
      var.telemetry_subscription_resource_id != null &&
      length([
        for config in try(mock.mock_data, []) : config
        if (
          config.mptf.block_labels[0] == "azapi_client_config" &&
          try(contains(keys(config.mptf.attributes.defaults), "subscription_resource_id"), false)
        )
      ]) == 0
    )
  }
  provider_mock_runs = {
    for name, providers in var.provider_mock_bindings : name => local.test_file.runs[name]
    if !contains(keys(local.test_file.runs[name].mptf.attributes), "providers")
  }
}

transform "update_in_place" "telemetry_mock" {
  for_each                  = local.telemetry_mock_updates
  target_block_address      = each.value.mptf.block_address
  match_nested_block_labels = true
  merge_object_attributes   = true
  dynamic_block_body        = <<-BODY
    mock_data "azapi_client_config" {
      defaults = {
        subscription_resource_id = ${jsonencode(var.telemetry_subscription_resource_id)}
      }
    }
  BODY
}

transform "update_in_place" "provider_mocks" {
  for_each             = local.provider_mock_runs
  target_block_address = each.value.mptf.block_address
  dynamic_block_body   = "providers = {\n${join("\n", [for name in sort(tolist(var.provider_mock_bindings[each.key])) : "  ${name} = ${name}"])}\n}\n"
}
