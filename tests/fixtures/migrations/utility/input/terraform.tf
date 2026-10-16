terraform {
  required_version = ">= 1.15.0, < 2.0.0"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    modtm = {
      source  = "Azure/modtm"
      version = "~> 0.3"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.12"
    }
  }
}
