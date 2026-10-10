variable "entra_group_names" {
  type        = set(string)
  description = "Configured group display names to resolve in this identity's tenant."
  default     = []

  validation {
    condition = alltrue([
      for name in var.entra_group_names :
      trimspace(name) != "" && name == trimspace(name) && !can(regex("[\\x00-\\x1f\\x7f]", name))
    ])
    error_message = "Entra group display names must be nonempty, trimmed strings without control characters."
  }
}

variable "expected_identity_context" {
  type = object({
    tenant_id            = string
    subscription_id      = string
    controller_client_id = string
    bicep_client_id      = optional(string)
  })
  description = "Expected BAMI tenant, identity subscription, and provisioning controller."
  nullable    = false

  validation {
    condition = (
      alltrue([
        for id in [
          var.expected_identity_context.tenant_id,
          var.expected_identity_context.subscription_id,
          var.expected_identity_context.controller_client_id
        ] : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id)) && lower(id) != "00000000-0000-0000-0000-000000000000"
      ])
    )
    error_message = "BAMI provider context requires nonempty tenant, subscription, and controller GUIDs."
  }
}

variable "identity_resource_group_name" {
  type        = string
  description = "Name of the resource group to create the identities in."
}

variable "identity_name" {
  type        = string
  description = "Optional dedicated Bicep module identity name; Terraform names use id-test-terraform- and the repository stem with reserved windows replaced by w5s."
  default     = null

  validation {
    condition     = var.identity_name == null ? true : can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{2,89}$", var.identity_name))
    error_message = "An explicit identity name must contain 3-90 letters, digits, underscores or hyphens."
  }
}

variable "github_workflow_ref" {
  type        = string
  description = "Optional top-level caller workflow binding in addition to the reusable job workflow."
  default     = null

  validation {
    condition     = var.github_workflow_ref == null ? true : can(regex("^[^/\\s@]+/[^/\\s@]+/\\.github/workflows/[^/\\s@]+\\.ya?ml@refs/heads/main$", var.github_workflow_ref))
    error_message = "The caller workflow must be a fully qualified workflow ref on trusted main."
  }
}

variable "github_repository_owner" {
  type        = string
  description = "Owner of the GitHub repositories."
}

variable "github_repository_name" {
  type        = string
  description = "Name of the GitHub repository."

  validation {
    condition = var.identity_name != null ? true : (
      length("id-test-terraform-${replace(trimprefix(lower(var.github_repository_name), "terraform-"), "windows", "w5s")}") <= 90 &&
      can(regex("^terraform-(azure|azurerm|azapi)-avm-(res|ptn|utl)-[a-z0-9]+(-[a-z0-9]+)*$", lower(var.github_repository_name)))
    )
    error_message = "Default test identity naming requires an AVM Terraform repository whose complete identity name fits the repository's 90-character limit."
  }
}

variable "github_repository_environment_names" {
  type        = set(string)
  description = "Names of the GitHub environments to create federated identity credentials for. The OIDC subject claim uses the `context` claim, which expands to `environment:<name>` for env-gated jobs, so one credential is created per environment."

  validation {
    condition = alltrue([
      for name in var.github_repository_environment_names :
      can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{2,119}$",
        var.github_workflow_ref == null ? "${local.owner_repo_name}-${name}" : "${local.owner_repo_name}-module-${name}"
      ))
    ])
    error_message = "Environment suffixes must keep federated credential names within 120 characters, including the optional module- prefix."
  }
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
