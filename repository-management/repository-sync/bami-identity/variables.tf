variable "tenant_id" {
  type        = string
  description = "Current BAMI tenant ID."
}

variable "subscription_id" {
  type        = string
  description = "BAMI administration subscription containing repository identities."
}

variable "controller_client_id" {
  type        = string
  description = "BAMI controller used only to provision dedicated test identities."
}

variable "management_group_id" {
  type        = string
  description = "BAMI management group for module test permissions."
}

variable "identity_resource_group_name" {
  type        = string
  description = "Existing BAMI resource group for repository identities."
}

variable "github_repository_owner" {
  type        = string
  description = "GitHub repository owner."
}

variable "github_repository_name" {
  type        = string
  description = "GitHub repository name."
}

variable "github_organization_id" {
  type        = string
  description = "Numeric GitHub organization ID used by federation."
}

variable "github_repository_id" {
  type        = string
  description = "Numeric GitHub repository ID used by federation."
}

variable "github_job_workflow_ref" {
  type        = string
  description = "Resolved reusable workflow reference used by federation."
}

variable "location" {
  type        = string
  description = "Location of the repository identity."
  default     = "eastus2"
}
