variable "policy_fixture_name" {
  type = string
}

resource "azapi_resource" "policy_violation" {
  location  = "westus3"
  name      = var.policy_fixture_name
  parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-avm-policy-fixture"
  type      = "Microsoft.EventHub/namespaces@2024-01-01"
  body = {
    sku = {
      name     = "Standard"
      tier     = "Standard"
      capacity = 1
    }
    properties = {
      isAutoInflateEnabled = false
      minimumTlsVersion    = "1.0"
      zoneRedundant        = false
    }
  }
}
