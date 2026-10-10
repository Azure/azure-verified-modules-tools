variable "modules" {
  type        = map(set(string))
  description = "Canonical root module paths and their accumulated Entra group display names."

  validation {
    condition = length(var.modules) > 0 && alltrue([
      for path, groups in var.modules :
      can(regex("^avm/(res|ptn|utl)/[a-z0-9]+(-[a-z0-9]+)*/[a-z0-9]+(-[a-z0-9]+)*$", path)) && length(path) <= 68
    ])
    error_message = "Identity discovery must contain canonical root Bicep module paths of at most 68 characters."
  }
}

variable "bami_test_settings" {
  type = object({
    tenant_id                    = string
    controller_client_id         = string
    bicep_client_id              = string
    admin_subscription_id        = string
    identity_resource_group_name = string
  })
  description = "Validated BAMI provisioning context, including the retained shared Bicep identity."
}

variable "github_repository_id" {
  type        = string
  description = "Verified immutable ID of Azure/bicep-registry-modules."
}

variable "github_organization_id" {
  type        = string
  description = "Verified immutable ID of the Azure GitHub organization."
}

variable "repository_sync_repository_id" {
  type        = string
  description = "Verified immutable ID of the Tools repository."
}

variable "location" {
  type        = string
  description = "Region for dedicated Bicep module identities."
  default     = "eastus2"
}
