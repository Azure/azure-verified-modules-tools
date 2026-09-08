variable "subscription_id" {
  type        = string
  default     = "c7fedf3b-cbde-4f68-8c81-7a0313adfc21"
  description = "Target Azure subscription ID for the dedicated backend bootstrap."
  nullable    = false

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id)) && var.subscription_id != "00000000-0000-0000-0000-000000000000"
    error_message = "subscription_id must be a nonzero UUID."
  }
}

variable "tenant_id" {
  type        = string
  default     = "70a036f6-8e4d-4615-bad6-149c02e7720d"
  description = "Microsoft Entra tenant ID containing the target subscription."
  nullable    = false

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.tenant_id)) && var.tenant_id != "00000000-0000-0000-0000-000000000000"
    error_message = "tenant_id must be a nonzero UUID."
  }
}

variable "location" {
  type        = string
  default     = "westus3"
  description = "Azure region for the resource group, storage account, and managed identity."
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,62}$", var.location))
    error_message = "location must be a lowercase Azure region identifier, such as westus3."
  }
}

variable "resource_group_name" {
  type        = string
  default     = "rg-avm-repository-sync-state-tme"
  description = "Name of a new, dedicated state resource group. Do not reuse an existing BAMI resource group."
  nullable    = false

  validation {
    condition     = can(regex("^[a-zA-Z0-9_().-]{1,89}[a-zA-Z0-9_()-]$", var.resource_group_name))
    error_message = "resource_group_name must be 2-90 alphanumeric, underscore, parenthesis, hyphen, or period characters and cannot end in a period."
  }
}

variable "storage_account_name" {
  type        = string
  default     = null
  description = "Optional globally unique storage account name. The default is stavmstate plus 14 SHA-256 hex characters derived from the subscription ID and resource group name."

  validation {
    condition     = var.storage_account_name == null ? true : can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be null or 3-24 lowercase letters and digits."
  }
}

variable "container_name" {
  type        = string
  default     = "tfstate"
  description = "Name of the private Terraform state container."
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.container_name)) && !strcontains(var.container_name, "--")
    error_message = "container_name must be 3-63 lowercase letters, digits, or single hyphens, beginning and ending with a letter or digit."
  }
}

variable "backend_identity_name" {
  type        = string
  default     = "id-avm-repository-sync-state-tme"
  description = "Name of a new, dedicated backend user-assigned managed identity; never an existing BAMI identity."
  nullable    = false

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{2,127}$", var.backend_identity_name))
    error_message = "backend_identity_name must be 3-128 letters, digits, hyphens, or underscores and begin with a letter or digit."
  }
}

variable "github_repository_owner_id" {
  type        = string
  default     = "6844498"
  description = "Stable numeric GitHub repository owner ID in the exact OIDC subject."
  nullable    = false

  validation {
    condition     = can(regex("^[1-9][0-9]*$", var.github_repository_owner_id))
    error_message = "github_repository_owner_id must be a positive numeric ID without leading zeroes."
  }
}

variable "github_repository_id" {
  type        = string
  default     = "1239632211"
  description = "Stable numeric GitHub repository ID in the exact OIDC subject."
  nullable    = false

  validation {
    condition     = can(regex("^[1-9][0-9]*$", var.github_repository_id))
    error_message = "github_repository_id must be a positive numeric ID without leading zeroes."
  }
}

variable "soft_delete_retention_days" {
  type        = number
  default     = 7
  description = "Retention for soft-deleted blobs and containers. Previous blob versions do not automatically expire."
  nullable    = false

  validation {
    condition     = var.soft_delete_retention_days >= 7 && var.soft_delete_retention_days <= 365 && floor(var.soft_delete_retention_days) == var.soft_delete_retention_days
    error_message = "soft_delete_retention_days must be a whole number from 7 to 365."
  }
}

variable "enable_delete_lock" {
  type        = bool
  default     = true
  description = "Create a CanNotDelete storage-account lock. This protects ARM resources, not blob data. Disabling it with retained or imported state removes the lock."
  nullable    = false
}

variable "tags" {
  type = map(string)
  default = {
    workload    = "avm-repository-sync"
    environment = "tme"
    managedBy   = "terraform"
  }
  description = "Tags applied to the dedicated resource group, storage account, and managed identity."
  nullable    = false
}
