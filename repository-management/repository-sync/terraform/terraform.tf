terraform {
  # `removed { lifecycle { destroy = false } }` (see modules/github/github.repository.removed_managed_files.tf)
  # requires Terraform 1.7+.
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
