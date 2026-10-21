variable "retained_provider_configurations" {
  type    = set(string)
  default = []
}

data "terraform" "cleanup_providers" {}
data "resource" "cleanup_resources" {}
data "data" "cleanup_data" {}
data "ephemeral" "cleanup_ephemeral" {}

locals {
  modtm_provider_exists = try(data.terraform.cleanup_providers.required_providers.modtm != null, false)
  modtm_resources = flatten([
    for resource_type, by_name in data.resource.cleanup_resources.result : [
      for name, resource in by_name : name if startswith(resource_type, "modtm_")
    ]
  ])
  modtm_data = flatten([
    for data_type, by_name in data.data.cleanup_data.result : [
      for name, source in by_name : name if startswith(data_type, "modtm_")
    ]
  ])
  modtm_ephemeral = [
    for resource_type in keys(data.ephemeral.cleanup_ephemeral.result) : resource_type
    if startswith(resource_type, "modtm_")
  ]
}

data "module" "cleanup_modtm_calls" {}

locals {
  cleanup_modtm_provider_call_used = anytrue([
    for name, call in data.module.cleanup_modtm_calls.result :
    try(length(regexall("(^|[\\s{,])\"?modtm\"?(?:\\s|#[^\\r\\n]*|//[^\\r\\n]*|/\\*[\\s\\S]*?\\*/)*=", call.providers)) > 0, false)
  ])
}

transform "remove_block_element" "drop_modtm_provider" {
  for_each             = local.modtm_provider_exists && length(local.modtm_resources) == 0 && length(local.modtm_data) == 0 && length(local.modtm_ephemeral) == 0 && !local.cleanup_modtm_provider_call_used && !contains(var.retained_provider_configurations, "modtm") ? toset([1]) : toset([])
  target_block_address = "terraform"
  paths                = ["required_providers.modtm"]
}
