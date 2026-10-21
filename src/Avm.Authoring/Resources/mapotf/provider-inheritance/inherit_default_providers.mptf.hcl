data "module" "provider_inheritance" {}

locals {
  module_provider_entries = {
    for name, call in data.module.provider_inheritance.result : name => object_entries(call.providers)
    if contains(keys(call), "providers") && can(object_entries(try(call.providers, {})))
  }
  inherited_provider_calls = {
    for name, entries in local.module_provider_entries : name => entries
    if length(entries) > 0 && alltrue([
      for provider, configuration in entries :
      !strcontains(provider, ".") && configuration == provider
    ])
  }
}

transform "remove_block_element" "inherit_default_providers" {
  for_each             = local.inherited_provider_calls
  target_block_address = "module.${each.key}"
  paths                = ["providers"]
}
