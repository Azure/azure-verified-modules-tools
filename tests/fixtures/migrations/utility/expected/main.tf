data "azapi_client_config" "this" {}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  avm_azapi_header         = "owner-controlled"
  create_example_resources = var.create_example_resources || var.create_mock_resources
  example_keys             = ["primary", "secondary"]
  example_resource_ids     = { for k, r in azapi_resource.example_rg : k => r.id }
  owner_headers            = { "X-Owner" = "modtm_telemetry.telemetry" }
  resource_group_prefix    = "rg-avm-azapi-mock"
}

module "shared_interfaces" {
  source  = "Azure/avm-utl-interfaces/azure"
  version = "0.9.0"

  location         = var.location
  enable_telemetry = var.enable_telemetry
}

resource "azapi_resource" "example_rg" {
  for_each = toset(local.create_example_resources ? local.example_keys : [])

  location  = var.location
  name      = "${local.resource_group_prefix}-${random_string.suffix.result}-${each.value}"
  parent_id = "/subscriptions/${data.azapi_client_config.this.subscription_id}"
  type      = var.resource_types.resource_group
  body = {
    tags = var.tags
  }
  create_headers         = var.enable_telemetry ? { "User-Agent" = local.avm_azapi_header } : null
  delete_headers         = merge({ "If-Match" = "*" }, local.owner_headers)
  read_headers           = local.owner_headers
  response_export_values = []
  tags                   = var.tags
  update_headers         = merge(local.owner_headers, { "X-Update" = "owner" })

  lifecycle {
    ignore_changes = [
      body.tags,
    ]
  }
}

resource "azapi_resource" "example_rg_singleton" {
  count = local.create_example_resources ? 1 : 0

  location  = var.location
  name      = "${local.resource_group_prefix}-${random_string.suffix.result}-singleton"
  parent_id = "/subscriptions/${data.azapi_client_config.this.subscription_id}"
  type      = var.resource_types.resource_group
  body = {
    tags = var.tags
  }
  response_export_values = []
  tags                   = var.tags

  depends_on = [
    azapi_resource.example_rg,
  ]
}
