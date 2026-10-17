data "resource" "telemetry_order" {
  resource_type = "azapi_resource"
}

locals {
  telemetry_order_resource = try(data.resource.telemetry_order.result.azapi_resource.telemetry, null)
  telemetry_order_generated = try(
    local.telemetry_order_resource.type == "Microsoft.Resources/deployments@2025-04-01" &&
    trim(local.telemetry_order_resource.name, "\"") == "$${local.avm_metadata.telemetryIdPrefix}.$${local.avm_telemetry_version_token}.$${local.avm_module_source_type}.$${substr(sha1(terraform_data.telemetry[0].id), 0, 4)}" &&
    length(local.telemetry_order_resource.lifecycle) == 1 &&
    length(local.telemetry_order_resource.lifecycle[0].precondition) == 1,
    false
  )
}

transform "reorder_attributes" "telemetry_precondition" {
  for_each             = local.telemetry_order_generated ? toset([1]) : toset([])
  target_block_address = "resource.azapi_resource.telemetry"
  nested_block_path    = ["lifecycle", "precondition"]
}
