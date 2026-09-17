provider "azurerm" {
  features {}
}

module "test" {
  source = "../../"

  location         = "westus3"
  enable_telemetry = false
}
