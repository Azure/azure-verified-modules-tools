data "resource" "azapi_data_plane_resource" {
  resource_type = "azapi_data_plane_resource"
}

data "resource" "azapi_resource" {
  resource_type = "azapi_resource"
}

data "resource" "azapi_update_resource" {
  resource_type = "azapi_update_resource"
}

locals {
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
}

transform "remove_block_element" full_headers {
  for_each             = local.all_azapi_resources_with_full_headers_map
  target_block_address = each.key
  paths                = ["create_headers", "delete_headers", "read_headers", "update_headers"]
}

transform "remove_block_element" azapi_update_resource_headers {
  for_each             = local.azapi_update_resources_map
  target_block_address = each.key
  paths                = ["read_headers", "update_headers"]
}