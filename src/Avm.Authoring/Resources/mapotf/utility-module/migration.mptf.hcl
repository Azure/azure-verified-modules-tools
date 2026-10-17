variable "module_updates" {
  type    = map(string)
  default = {}
}

variable "provider_mappings" {
  type    = map(string)
  default = {}
}

variable "remove_provider_maps" {
  type    = set(string)
  default = []
}

variable "new_inputs" {
  type    = map(string)
  default = {}
}

variable "provider_requirement" {
  type    = string
  default = ""
}

variable "remove_requirements" {
  type    = set(string)
  default = []
}

data "module" "utility" {}
data "variable" "utility" {}
data "terraform" "utility" {}
data "resource" "utility" {}
data "data" "utility" {}
data "ephemeral" "utility" {}

transform "update_in_place" "utility_calls" {
  for_each             = var.module_updates
  target_block_address = "module.${each.key}"
  dynamic_block_body   = each.value
}

transform "update_in_place" "utility_provider_mappings" {
  for_each             = var.provider_mappings
  target_block_address = "module.${each.key}"
  dynamic_block_body   = "providers = ${each.value}\n"
}

transform "remove_block_element" "utility_provider_maps" {
  for_each             = var.remove_provider_maps
  target_block_address = "module.${each.value}"
  paths                = ["providers"]
}

transform "new_block" "utility_location_required" {
  for_each       = try(var.new_inputs.location == "required", false) ? toset(["location"]) : toset([])
  new_block_type = "variable"
  labels         = ["location"]
  filename       = "variables.tf"
  asraw {
    type        = string
    description = "The Azure region for this module's resources or telemetry deployment."
    nullable    = false
  }
}

transform "new_block" "utility_location_example" {
  for_each       = try(var.new_inputs.location == "example", false) ? toset(["location"]) : toset([])
  new_block_type = "variable"
  labels         = ["location"]
  filename       = "variables.tf"
  asraw {
    type        = string
    default     = "eastus"
    description = "The Azure region for this module's resources or telemetry deployment."
    nullable    = false
  }
}

transform "new_block" "utility_enable_telemetry" {
  for_each       = contains(keys(var.new_inputs), "enable_telemetry") ? toset(["enable_telemetry"]) : toset([])
  new_block_type = "variable"
  labels         = ["enable_telemetry"]
  filename       = "variables.tf"
  asraw {
    type     = bool
    default  = true
    nullable = false
  }
}

transform "reorder_attributes" "utility_terraform" {
  for_each                 = length(var.provider_requirement) > 0 && try(data.terraform.utility.block != null, false) ? toset(["1"]) : toset([])
  target_block_address     = "terraform"
  sort_body_alphabetically = false
}

transform "update_in_place" "utility_requirement" {
  for_each                = length(var.provider_requirement) > 0 && try(data.terraform.utility.block != null, false) ? toset(["1"]) : toset([])
  target_block_address    = "terraform"
  merge_object_attributes = true
  dynamic_block_body      = var.provider_requirement
  depends_on             = [transform.reorder_attributes.utility_terraform]
}

transform "new_block" "utility_requirement" {
  for_each       = length(var.provider_requirement) > 0 && !try(data.terraform.utility.block != null, false) ? toset(["1"]) : toset([])
  new_block_type = "terraform"
  labels         = []
  filename       = "terraform.tf"
  body           = "\n${var.provider_requirement}"
}

transform "remove_block_element" "utility_requirements" {
  for_each             = var.remove_requirements
  target_block_address = "terraform"
  paths                = ["required_providers.${each.value}"]
}
