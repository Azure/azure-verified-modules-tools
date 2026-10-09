variable "telemetry_subscription_resource_id" {
  type    = string
  default = null
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
