data "terraform" "test_providers" {}
data "resource" "test_resources" {}
data "data" "test_data" {}

locals {
  modtm_provider_exists = try(data.terraform.test_providers.required_providers.modtm != null, false)
  modtm_resources = flatten([
    for resource_type, by_name in data.resource.test_resources.result : [
      for name, resource in by_name : name if startswith(resource_type, "modtm_")
    ]
  ])
  modtm_data = flatten([
    for data_type, by_name in data.data.test_data.result : [
      for name, source in by_name : name if startswith(data_type, "modtm_")
    ]
  ])
}

transform "remove_block_element" "drop_modtm_provider" {
  for_each             = local.modtm_provider_exists && length(local.modtm_resources) == 0 && length(local.modtm_data) == 0 ? toset([1]) : toset([])
  target_block_address = "terraform"
  paths                = ["required_providers.modtm"]
}
