provider "azapi" {
  subscription_id              = var.subscription_id
  tenant_id                    = var.tenant_id
  skip_provider_registration   = true
  disable_terraform_partner_id = true
}

provider "azurerm" {
  subscription_id                 = var.subscription_id
  tenant_id                       = var.tenant_id
  resource_provider_registrations = "none"
  storage_use_azuread             = true
  disable_terraform_partner_id    = true

  features {}
}
