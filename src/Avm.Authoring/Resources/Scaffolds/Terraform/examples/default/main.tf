terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.12"
    }
  }
}

provider "azapi" {}

module "test" {
  source = "../../"

  location = "westus3"
  name     = "rg-avm-module-example"

  enable_telemetry = false
}
