terraform {
  required_providers {
    github = {
      source = "integrations/github"
    }
  }
}

variable "github_repository_name" {
  type = string
}

resource "github_repository" "this" {
  name       = var.github_repository_name
  visibility = "public"

  template {
    owner                = "Azure"
    repository           = "terraform-azurerm-avm-template"
    include_all_branches = false
  }

  lifecycle {
    prevent_destroy = true
  }
}
