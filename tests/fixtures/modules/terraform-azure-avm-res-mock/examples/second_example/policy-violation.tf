variable "policy_fixture_name" {
  type = string
}

resource "azapi_resource" "policy_violation" {
  type      = "Microsoft.EventHub/namespaces@2024-01-01"
  name      = var.policy_fixture_name
  location  = "westus3"
  parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-avm-policy-fixture"

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
