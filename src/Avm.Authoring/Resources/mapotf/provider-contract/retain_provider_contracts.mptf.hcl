variable "provider_contract_sources" {
  type    = set(string)
  default = []
}

variable "provider_contract_bindings" {
  type    = set(string)
  default = []
}

variable "provider_contract_unused" {
  type    = set(string)
  default = []
}

variable "provider_contract_original_requirements" {
  type    = map(map(string))
  default = {}
}

variable "provider_contract_cleanup" {
  type    = bool
  default = false
}

data "terraform" "provider_contract" {}
data "module" "provider_contract" {}
data "resource" "provider_contract" {}
data "data" "provider_contract" {}
data "ephemeral" "provider_contract" {}

locals {
  provider_contract_requirements = data.terraform.provider_contract.required_providers
  provider_contract_source_names = {
    for name, requirement in local.provider_contract_requirements :
    name => try(length(requirement.source) > 0, false) ? lower(requirement.source) : "hashicorp/${name}"
  }
  provider_contract_addresses = {
    for name, source in local.provider_contract_source_names : name => (
      length(split("/", source)) == 1 ? "registry.terraform.io/hashicorp/${source}" :
      length(split("/", source)) == 2 ? "registry.terraform.io/${source}" : source
    )
  }
  provider_contract_original_sources = {
    for name, requirement in var.provider_contract_original_requirements :
    name => try(length(requirement.source) > 0, false) ? lower(requirement.source) : "hashicorp/${name}"
  }
  provider_contract_original_addresses = {
    for name, source in local.provider_contract_original_sources : name => (
      length(split("/", source)) == 1 ? "registry.terraform.io/hashicorp/${source}" :
      length(split("/", source)) == 2 ? "registry.terraform.io/${source}" : source
    )
  }
  provider_contract_versions = toset([
    for name, requirement in local.provider_contract_requirements : name
    if contains(var.provider_contract_sources, local.provider_contract_addresses[name]) &&
    try(local.provider_contract_original_addresses[name] == local.provider_contract_addresses[name] &&
    var.provider_contract_original_requirements[name].version == requirement.version &&
    length(requirement.version) > 0, false)
  ])
  provider_contract_names = toset([
    for name, address in local.provider_contract_addresses : name
    if contains(var.provider_contract_sources, address) && (
      contains(var.provider_contract_bindings, name) ||
      contains(local.provider_contract_versions, name)
    )
  ])
  provider_contract_call_bindings = {
    for name, call in data.module.provider_contract.result : name => {
      source    = call.source
      providers = keys(object_entries(call.providers))
    }
    if contains(keys(call), "providers") && can(object_entries(try(call.providers, {})))
  }
  provider_contract_objects = concat(
    [for address, resource in data.resource.provider_contract.result : { address = address, provider = try(resource.provider, "") }],
    [for address, resource in data.data.provider_contract.result : { address = address, provider = try(resource.provider, "") }],
    [for address, resource in data.ephemeral.provider_contract.result : { address = address, provider = try(resource.provider, "") }]
  )
  provider_contract_used = {
    for name, requirement in local.provider_contract_requirements : name => (
      contains(var.provider_contract_bindings, name) ||
      contains(local.provider_contract_versions, name) ||
      try(length(requirement.configuration_aliases) > 0, false) ||
      anytrue([
        for resource in local.provider_contract_objects :
        startswith(resource.address, "${name}_") || try(resource.provider == name || startswith(resource.provider, "${name}."), false)
      ]) ||
      anytrue([
        for call_name, call in data.module.provider_contract.result :
        contains(keys(call), "providers") && try(anytrue([
          for target, configuration in object_entries(call.providers) :
          configuration == name || startswith(configuration, "${name}.")
        ]), true)
      ])
    )
  }
}

transform "remove_block_element" "retire_unused_provider_contracts" {
  for_each = toset([
    for name, used in local.provider_contract_used : name
    if var.provider_contract_cleanup && contains(var.provider_contract_unused, name) && !used
  ])
  target_block_address = "terraform"
  paths                = ["required_providers.${each.key}"]
}
