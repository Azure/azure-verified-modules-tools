# Example AVM-shaped resources/data/locals for governance fixture coverage.
# Azure resource blocks are gated by both creation inputs (default false) so
# that pr-check terraform plan, terraform test integration, and any other apply path do not
# provision real Azure resources by default. The unit test (tests/unit/unit.tftest.hcl) sets
# the flag to true to exercise the apply path with mock providers.

data "azapi_client_config" "this" {}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  create_example_resources = var.create_example_resources || var.create_mock_resources
  example_keys             = ["primary", "secondary"]
  example_resource_ids     = { for k, r in azapi_resource.example_rg : k => r.id }
  resource_group_prefix    = "rg-avm-azapi-mock"
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
  response_export_values = []
  tags                   = var.tags

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
