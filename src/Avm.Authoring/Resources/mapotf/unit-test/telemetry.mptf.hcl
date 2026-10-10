variable "telemetry_subscription_resource_ids" {
  type    = map(string)
  default = {}
}

variable "provider_mock_bindings" {
  type    = map(string)
  default = {}
}

locals {
  telemetry_mock_updates = {
    for name, mock in local.test_file.mock_providers : name => mock
    if (
      contains(keys(var.telemetry_subscription_resource_ids), name) &&
      length([
        for config in try(mock.mock_data, []) : config
        if (
          config.mptf.block_labels[0] == "azapi_client_config" &&
          try(contains(keys(config.mptf.attributes.defaults), "subscription_resource_id"), false)
        )
      ]) == 0
    )
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
        subscription_resource_id = ${jsonencode(var.telemetry_subscription_resource_ids[each.key])}
      }
    }
  BODY
}

transform "update_in_place" "provider_mocks" {
  for_each             = var.provider_mock_bindings
  target_block_address = local.test_file.runs[each.key].mptf.block_address
  dynamic_block_body   = "providers = ${each.value}\n"
}
