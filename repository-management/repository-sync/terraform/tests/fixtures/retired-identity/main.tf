terraform {
  required_providers {
    azapi = {
      source = "Azure/azapi"
    }
    azuread = {
      source = "hashicorp/azuread"
    }
  }
}

module "azure" {
  source = "./azure"
  count  = 1
}
