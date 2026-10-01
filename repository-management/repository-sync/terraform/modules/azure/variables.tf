variable "management_group_id" {
  type        = string
  description = "Id of the management group to create the role assignment in."
}

variable "bami_group_settings" {
  type = object({
    tenant_id                     = string
    controller_client_id          = string
    entra_readers_group_id        = string
    test_identity_owners_group_id = string
    fabric_admins_group_id        = string
    fabric_admin_apis             = bool
  })
  description = "Pinned BAMI access groups; null preserves legacy direct Owner and readers lookup."
  default     = null

  validation {
    condition = var.bami_group_settings == null ? true : (
      alltrue([
        for id in [
          var.bami_group_settings.tenant_id,
          var.bami_group_settings.controller_client_id,
          var.bami_group_settings.entra_readers_group_id,
          var.bami_group_settings.test_identity_owners_group_id,
          var.bami_group_settings.fabric_admins_group_id
        ] : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id)) && lower(id) != "00000000-0000-0000-0000-000000000000"
      ]) &&
      length(distinct([
        lower(var.bami_group_settings.entra_readers_group_id),
        lower(var.bami_group_settings.test_identity_owners_group_id),
        lower(var.bami_group_settings.fabric_admins_group_id)
      ])) == 3
    )
    error_message = "BAMI requires nonempty tenant/controller GUIDs and three distinct pinned group object IDs."
  }
}

variable "identity_resource_group_name" {
  type        = string
  description = "Name of the resource group to create the identities in."
}

variable "github_repository_owner" {
  type        = string
  description = "Owner of the GitHub repositories."
}

variable "github_repository_name" {
  type        = string
  description = "Name of the GitHub repository."
}

variable "github_repository_environment_names" {
  type        = set(string)
  description = "Names of the GitHub environments to create federated identity credentials for. The OIDC subject claim uses the `context` claim, which expands to `environment:<name>` for env-gated jobs, so one credential is created per environment."
}

variable "location" {
  type        = string
  description = "Location of the resources."
}

variable "is_protected_repo" {
  type        = bool
  description = "Whether the repository is protected and requires pull request approval."
}

variable "github_job_workflow_ref" {
  type        = string
  description = "GitHub Actions job workflow ref."
}

variable "github_organization_id" {
  type        = string
  description = "ID of the GitHub organization."
}

variable "github_repository_id" {
  type        = string
  description = "ID of the GitHub repository."
}

variable "repository_sync_repository_id" {
  type        = string
  description = "Verified numeric ID of the tools repository running repository sync."

  validation {
    condition     = can(regex("^[1-9][0-9]*$", var.repository_sync_repository_id))
    error_message = "repository_sync_repository_id must be a positive decimal GitHub repository ID."
  }
}
