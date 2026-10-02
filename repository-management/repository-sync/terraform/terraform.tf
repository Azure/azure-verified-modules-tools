terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.12"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.9"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }
  backend "azurerm" {}
}

provider "github" {
  owner = var.github_repository_owner
}

provider "azapi" {
  tenant_id       = var.bami_test_settings == null ? null : var.bami_test_settings.tenant_id
  subscription_id = var.bami_test_settings == null ? null : var.bami_test_settings.admin_subscription_id
  client_id       = var.bami_test_settings == null ? null : var.bami_test_settings.controller_client_id
  use_oidc        = true
  use_cli         = false
  use_msi         = false
}

provider "azuread" {
  tenant_id = var.bami_test_settings == null ? null : var.bami_test_settings.tenant_id
  client_id = var.bami_test_settings == null ? null : var.bami_test_settings.controller_client_id
  use_oidc  = true
  use_cli   = false
  use_msi   = false
}
