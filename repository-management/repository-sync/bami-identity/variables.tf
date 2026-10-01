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

variable "entra_readers_group_id" {
  type        = string
  description = "Pinned object ID of avm-test-entra-readers in the BAMI tenant."
}

variable "test_identity_owners_group_id" {
  type        = string
  description = "Pinned object ID of avm-test-identity-owners in the BAMI tenant."
}

variable "fabric_admins_group_id" {
  type        = string
  description = "Pinned object ID of avm-test-fabric-admins in the BAMI tenant."
}

variable "fabric_admin_apis" {
  type        = bool
  description = "Explicit repository opt-in to tenant-wide Fabric admin APIs."
  default     = false
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

variable "repository_sync_repository_id" {
  type        = string
  description = "Verified numeric ID of the tools repository running repository sync."

  validation {
    condition     = can(regex("^[1-9][0-9]*$", var.repository_sync_repository_id))
    error_message = "repository_sync_repository_id must be a positive decimal GitHub repository ID."
  }
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
