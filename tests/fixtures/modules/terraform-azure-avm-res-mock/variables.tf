variable "location" {
  type        = string
  description = "The Azure location where resources will be created"
  nullable    = false
}

variable "ignore_body_changes" {
  type = object({
    resource_group = optional(list(string), [])
  })
  default     = {}
  description = "A map of resource body properties to ignore when comparing deployment state."
  nullable    = false
}

variable "private_endpoints_manage_dns_zone_group" {
  type        = bool
  default     = true
  description = "Controls whether private DNS zone groups are managed by the module."
  nullable    = false
}

variable "resource_types" {
  type = object({
    resource_group = optional(string, "Microsoft.Resources/resourceGroups@2024-03-01")
  })
  default     = {}
  description = "A map of resource type API versions used by the module."
  nullable    = false
}

variable "retry" {
  type = object({
    error_message_regex  = optional(list(string))
    interval_seconds     = optional(number)
    max_interval_seconds = optional(number)
  })
  default     = {}
  description = "Controls retry behavior for supported AzAPI resources."
}

variable "timeouts" {
  type = object({
    create = optional(string)
    read   = optional(string)
    update = optional(string)
    delete = optional(string)
  })
  default     = {}
  description = "Controls operation timeouts for supported AzAPI resources."
}
