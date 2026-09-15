terraform {
  required_version = ">= 1.7.0"
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.12"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.9"
    }
  }
  backend "azurerm" {}
}

provider "azapi" {
  tenant_id       = var.tenant_id
  subscription_id = var.subscription_id
  client_id       = var.controller_client_id
  use_oidc        = true
  use_cli         = false
  use_msi         = false
}

provider "azuread" {
  tenant_id = var.tenant_id
  client_id = var.controller_client_id
  use_oidc  = true
  use_cli   = false
  use_msi   = false
}
