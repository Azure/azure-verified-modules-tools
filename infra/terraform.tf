terraform {
  required_version = ">= 1.10.0, < 2.0"

  # One-shot bootstrap only. Once this state is discarded, import before any subsequent apply.
  backend "local" {}

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.11"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.60.0, < 5.4.1"
    }
    modtm = {
      source  = "Azure/modtm"
      version = "~> 0.3"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0, < 4.0.0"
    }
  }
}
