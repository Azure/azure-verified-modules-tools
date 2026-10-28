variable "provider_source_facts" {
  type    = map(set(string))
  default = {}
}

variable "local_provider_requirements" {
  type = map(object({
    declared         = set(string)
    original_sources = map(string)
  }))
  default = {}
}

variable "provider_configuration_facts" {
  type    = set(string)
  default = []
}

variable "provider_alias_facts" {
  type    = set(string)
  default = []
}

variable "calls_requiring_azapi" {
  type    = set(string)
  default = []
}

variable "provider_facts_complete" {
  type    = bool
  default = false
}

data "module" "utility" {}
data "variable" "utility" {}
data "terraform" "utility" {}
data "resource" "utility" {}
data "data" "utility" {}
data "ephemeral" "utility" {}

variable "target_scope" {
  type    = string
  default = "module"
}

variable "preserve_selections" {
  type    = bool
  default = false
}

variable "apply_utility_migration" {
  type    = bool
  default = true
}

locals {
  utility_versions = {
    "azure/avm-utl-regions/azurerm"  = "0.13.0"
    "azure/avm-utl-interfaces/azure" = "0.9.0"
    "azure/naming/azurerm"           = "0.2.0"
  }
  utility_candidates = {
    for name, call in data.module.utility.result : name => merge(call, {
      source_key = trimprefix(lower(call.source), "registry.terraform.io/")
      version_pin = trimspace(trimprefix(try(call.version, ""), "="))
    })
    if contains(keys(local.utility_versions), trimprefix(lower(call.source), "registry.terraform.io/"))
  }
  utility_review_calls = {
    for name, call in local.utility_candidates : name => call
    if !can(regex("^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$", call.version_pin))
  }
  utility_pinned_calls = {
    for name, call in local.utility_candidates : name => merge(call, {
      version_parts = [for component in regex("^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$", call.version_pin) : tonumber(component)]
      target_version = local.utility_versions[call.source_key]
      target_parts   = [for component in split(".", local.utility_versions[call.source_key]) : tonumber(component)]
      legacy_naming  = call.source_key == "azure/naming/azurerm"
    })
    if !contains(keys(local.utility_review_calls), name)
  }
  utility_selected_calls = {
    for name, call in local.utility_pinned_calls : name => merge(call, {
      upgrade = call.legacy_naming || (
        call.version_parts[0] < call.target_parts[0] ||
        (call.version_parts[0] == call.target_parts[0] && call.version_parts[1] < call.target_parts[1]) ||
        (call.version_parts[0] == call.target_parts[0] && call.version_parts[1] == call.target_parts[1] && call.version_parts[2] < call.target_parts[2])
      )
    })
    if var.apply_utility_migration && !var.preserve_selections && (
      call.legacy_naming ||
      call.version_parts[0] < call.target_parts[0] ||
      (call.version_parts[0] == call.target_parts[0] && call.version_parts[1] < call.target_parts[1]) ||
      (call.version_parts[0] == call.target_parts[0] && call.version_parts[1] == call.target_parts[1] && call.version_parts[2] <= call.target_parts[2])
    )
  }
  utility_telemetry_calls = {
    for name, call in local.utility_selected_calls : name => call
    if !call.legacy_naming
  }
  utility_update_calls = {
    for name, call in local.utility_selected_calls : name => call
    if call.upgrade || call.legacy_naming
  }
  utility_missing_location_calls = {
    for name, call in local.utility_telemetry_calls : name => call
    if !contains(keys(call), "location")
  }
  utility_missing_telemetry_calls = {
    for name, call in local.utility_telemetry_calls : name => call
    if var.target_scope != "test" && !contains(keys(call), "enable_telemetry")
  }
  utility_validated_calls = local.utility_selected_calls
  provider_addresses = {
    modtm  = "registry.terraform.io/azure/modtm"
    random = "registry.terraform.io/hashicorp/random"
  }
  provider_mapping_entries = {
    for name, call in data.module.utility.result : name => object_entries(call.providers)
    if contains(keys(call), "providers") && can(object_entries(call.providers))
  }
  retired_local_random_contracts = toset([
    for name, requirements in var.local_provider_requirements : name
    if !contains(requirements.declared, "random") &&
    try(contains(["", "random", "hashicorp/random", "registry.terraform.io/hashicorp/random"],
    lower(requirements.original_sources.random)), false)
  ])
  provider_mapping_review = {
    for name, call in data.module.utility.result : name => call
    if contains(keys(call), "providers") &&
    (
      (contains(keys(var.provider_source_facts), name) &&
      !contains(var.provider_source_facts[name], local.provider_addresses.modtm)) ||
      contains(local.retired_local_random_contracts, name)
    ) &&
    !can(object_entries(call.providers))
  }
  modtm_provider_mappings = {
    for name, entries in local.provider_mapping_entries : name => entries
    if contains(keys(var.provider_source_facts), name) &&
    !contains(var.provider_source_facts[name], local.provider_addresses.modtm) &&
    try(entries.modtm == "modtm", false)
  }
  random_provider_mappings = {
    for name, entries in local.provider_mapping_entries : name => entries
    if contains(local.retired_local_random_contracts, name) &&
    try(entries.random == "random", false)
  }
  retained_provider_mappings = {
    for name, entries in local.modtm_provider_mappings : name => entries
    if length(keys(entries)) > 1
  }
  azapi_provider_mappings = {
    for name, entries in local.retained_provider_mappings : name => entries
    if contains(var.calls_requiring_azapi, name) && !contains(keys(entries), "azapi")
  }
  provider_requirement_uses = {
    for name, address in local.provider_addresses : name => (
      contains(var.provider_configuration_facts, name) ||
      contains(var.provider_alias_facts, name) ||
      length([
        for resource_name in concat(
          keys(data.resource.utility.result),
          keys(data.data.utility.result),
          keys(data.ephemeral.utility.result)
        ) : resource_name
        if length(regexall("^${name}_", resource_name)) > 0
      ]) > 0 ||
      length([
        for call_name, entries in local.provider_mapping_entries : entries
        if contains(keys(entries), name) &&
        !(name == "modtm" && contains(keys(local.modtm_provider_mappings), call_name)) &&
        !(name == "random" && contains(keys(local.random_provider_mappings), call_name))
      ]) > 0 ||
      length([
        for call_name in keys(var.provider_source_facts) : call_name
        if contains(var.provider_source_facts[call_name], address)
      ]) > 0
    )
  }
  retired_provider_requirements = toset([
    for name, address in local.provider_addresses : name
    if contains(keys(data.terraform.utility.required_providers), name) &&
    var.provider_facts_complete &&
    (
      lower(try(data.terraform.utility.required_providers[name].source, "")) == address ||
      lower(try(data.terraform.utility.required_providers[name].source, "")) == trimprefix(address, "registry.terraform.io/")
    ) &&
    !local.provider_requirement_uses[name]
  ])
}

transform "update_in_place" "utility_calls" {
  for_each             = local.utility_update_calls
  target_block_address = "module.${each.key}"
  dynamic_block_body = join("\n", compact([
    each.value.upgrade ? "version = \"${each.value.target_version}\"" : "",
    each.value.legacy_naming ? "source = \"Azure/avm-utl-naming/azure\"" : "",
    each.value.legacy_naming && contains(keys(each.value), "legacy_mode") ? "legacy_mode = false" : "",
  ]))
}

transform "update_in_place" "utility_location_calls" {
  for_each             = local.utility_missing_location_calls
  target_block_address = "module.${each.key}"
  asraw {
    location = var.location
  }
}

transform "update_in_place" "utility_telemetry_calls" {
  for_each             = local.utility_missing_telemetry_calls
  target_block_address = "module.${each.key}"
  asraw {
    enable_telemetry = var.enable_telemetry
  }
}

transform "remove_object_attributes" "utility_modtm_provider_mappings" {
  for_each             = local.modtm_provider_mappings
  target_block_address = "module.${each.key}"
  attribute_path       = ["providers"]
  keys                 = ["modtm"]
  remove_empty_attribute = true
}

transform "remove_object_attributes" "local_random_provider_mappings" {
  for_each               = local.random_provider_mappings
  target_block_address   = "module.${each.key}"
  attribute_path         = ["providers"]
  keys                   = ["random"]
  remove_empty_attribute = true
  depends_on             = [transform.remove_object_attributes.utility_modtm_provider_mappings]
}

transform "update_in_place" "utility_azapi_provider_mappings" {
  for_each                = local.azapi_provider_mappings
  target_block_address    = "module.${each.key}"
  merge_object_attributes = true
  depends_on              = [
    transform.remove_object_attributes.utility_modtm_provider_mappings,
    transform.remove_object_attributes.local_random_provider_mappings,
  ]
  asraw {
    providers = {
      azapi = azapi
    }
  }
}

transform "reorder_attributes" "utility_terraform" {
  for_each                 = length(local.azapi_provider_mappings) > 0 && !contains(keys(data.terraform.utility.required_providers), "azapi") && try(data.terraform.utility.block != null, false) ? toset(["1"]) : toset([])
  target_block_address     = "terraform"
  sort_body_alphabetically = false
}

transform "update_in_place" "utility_azapi_requirement" {
  for_each                = length(local.azapi_provider_mappings) > 0 && !contains(keys(data.terraform.utility.required_providers), "azapi") && try(data.terraform.utility.block != null, false) ? toset(["1"]) : toset([])
  target_block_address    = "terraform"
  merge_object_attributes = true
  dynamic_block_body = <<-EOT
required_providers {
  azapi = {
    source  = "Azure/azapi"
    version = "~> 2.12"
  }
}
EOT
  depends_on = [transform.reorder_attributes.utility_terraform]
}

transform "new_block" "utility_azapi_requirement" {
  for_each       = length(local.azapi_provider_mappings) > 0 && !contains(keys(data.terraform.utility.required_providers), "azapi") && !try(data.terraform.utility.block != null, false) ? toset(["1"]) : toset([])
  new_block_type = "terraform"
  labels         = []
  filename       = "terraform.tf"
  body = <<-EOT

required_providers {
  azapi = {
    source  = "Azure/azapi"
    version = "~> 2.12"
  }
}
EOT
}

transform "new_block" "utility_location_required" {
  for_each       = length(local.utility_missing_location_calls) > 0 && !contains(keys(data.variable.utility.result), "location") && var.target_scope != "example" ? toset(["location"]) : toset([])
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
  for_each       = length(local.utility_missing_location_calls) > 0 && !contains(keys(data.variable.utility.result), "location") && var.target_scope == "example" ? toset(["location"]) : toset([])
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
  for_each       = length(local.utility_missing_telemetry_calls) > 0 && !contains(keys(data.variable.utility.result), "enable_telemetry") ? toset(["enable_telemetry"]) : toset([])
  new_block_type = "variable"
  labels         = ["enable_telemetry"]
  filename       = "variables.tf"
  asraw {
    type     = bool
    default  = true
    nullable = false
  }
}

transform "remove_block_element" "utility_requirements" {
  for_each             = local.retired_provider_requirements
  target_block_address = "terraform"
  paths                = ["required_providers.${each.value}"]
}
