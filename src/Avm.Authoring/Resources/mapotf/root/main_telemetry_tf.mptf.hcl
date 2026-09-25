data "variable" "enable_telemetry" {
  name = "enable_telemetry"
}

data "variable" "telemetry_location" {
  name = "telemetry_location"
}

data "variable" "location" {
  name = "location"
}

data "data" "azurerm_client_config" {
  data_source_type = "azurerm_client_config"
}

data "data" "azapi_client_config" {
  data_source_type = "azapi_client_config"
}

data "data" "modtm_module_source" {
  data_source_type = "modtm_module_source"
}

data "resource" "random_uuid" {
  resource_type = "random_uuid"
}

data "resource" "modtm_telemetry" {
  resource_type = "modtm_telemetry"
}

data "resource" "terraform_data" {
  resource_type = "terraform_data"
}

data "resource" "azapi_resource" {
  resource_type = "azapi_resource"
}

data "resource" "all_resources" {}
data "data" "all_data" {}
data "terraform" "providers" {}

data "local" "main_location" {
  name = "main_location"
}

data "local" "avm_metadata" {
  name = "avm_metadata"
}

locals {
  enable_telemetry_exists    = length(data.variable.enable_telemetry.result) == 1
  telemetry_location_exists  = length(data.variable.telemetry_location.result) == 1
  location_exists            = length(data.variable.location.result) == 1
  main_location_exists       = length(data.local.main_location.result) == 1
  avm_metadata_exists        = length(data.local.avm_metadata.result) == 1
  main_location_expression   = local.location_exists ? "var.telemetry_location != null ? var.telemetry_location : var.location" : "var.telemetry_location"
  azurerm_client_exists      = try(data.data.azurerm_client_config.result["azurerm_client_config"].telemetry != null, false)
  azapi_client_exists        = try(data.data.azapi_client_config.result["azapi_client_config"].telemetry != null, false)
  modtm_module_source_exists = try(data.data.modtm_module_source.result["modtm_module_source"].telemetry != null, false)
  random_uuid_exists         = try(data.resource.random_uuid.result["random_uuid"].telemetry != null, false)
  modtm_telemetry_exists     = try(data.resource.modtm_telemetry.result["modtm_telemetry"].telemetry != null, false)
  terraform_data_exists     = try(data.resource.terraform_data.result["terraform_data"].telemetry != null, false)
  azapi_resource_exists     = try(data.resource.azapi_resource.result["azapi_resource"].telemetry != null, false)
  modtm_provider_exists      = try(data.terraform.providers.required_providers.modtm != null, false)
  random_provider_exists     = try(data.terraform.providers.required_providers.random != null, false)

  other_modtm_resources = flatten([
    for resource_type, by_name in data.resource.all_resources.result : [
      for name, resource in by_name : name
      if startswith(resource_type, "modtm_") && !(resource_type == "modtm_telemetry" && name == "telemetry")
    ]
  ])
  other_modtm_data = flatten([
    for data_type, by_name in data.data.all_data.result : [
      for name, source in by_name : name
      if startswith(data_type, "modtm_") && !(data_type == "modtm_module_source" && name == "telemetry")
    ]
  ])
  other_random_resources = flatten([
    for resource_type, by_name in data.resource.all_resources.result : [
      for name, resource in by_name : name
      if startswith(resource_type, "random_") && !(resource_type == "random_uuid" && name == "telemetry")
    ]
  ])
  other_random_data = flatten([
    for data_type, by_name in data.data.all_data.result : [
      for name, source in by_name : name
      if startswith(data_type, "random_")
    ]
  ])
}

transform "new_block" "new_enable_telemetry" {
  for_each       = !local.enable_telemetry_exists ? toset([1]) : toset([])
  new_block_type = "variable"
  labels         = ["enable_telemetry"]
  filename       = "variables.tf"
  asraw {
    type        = bool
    default     = true
    description = <<DESCRIPTION
This variable controls whether or not telemetry is enabled for the module.
For more information see <https://aka.ms/avm/telemetryinfo>.
If it is set to false, then no telemetry will be collected.
DESCRIPTION
    nullable    = false
  }
}

transform "update_in_place" "enable_telemetry" {
  for_each             = local.enable_telemetry_exists ? toset([1]) : toset([])
  target_block_address = "variable.enable_telemetry"
  asraw {
    type        = bool
    default     = true
    description = <<DESCRIPTION
This variable controls whether or not telemetry is enabled for the module.
For more information see <https://aka.ms/avm/telemetryinfo>.
If it is set to false, then no telemetry will be collected.
DESCRIPTION
    nullable    = false
  }
}

transform "new_block" "new_telemetry_location_with_location" {
  for_each       = !local.telemetry_location_exists && local.location_exists ? toset([1]) : toset([])
  new_block_type = "variable"
  labels         = ["telemetry_location"]
  filename       = "variables.tf"
  asraw {
    type        = string
    default     = null
    description = "Optional. Location for the subscription-scoped AVM telemetry deployment. Defaults to the module location; override it for another region or cloud. See https://aka.ms/avm/telemetry."
  }
}

transform "new_block" "new_telemetry_location_without_location" {
  for_each       = !local.telemetry_location_exists && !local.location_exists ? toset([1]) : toset([])
  new_block_type = "variable"
  labels         = ["telemetry_location"]
  filename       = "variables.tf"
  asraw {
    type        = string
    default     = "westus2"
    description = "Optional. Location for the subscription-scoped AVM telemetry deployment. Defaults to westus2; override it for another region or cloud. See https://aka.ms/avm/telemetry."
    nullable    = false
  }
}

transform "update_in_place" "telemetry_location_with_location" {
  for_each             = local.telemetry_location_exists && local.location_exists ? toset([1]) : toset([])
  target_block_address = "variable.telemetry_location"
  asraw {
    type    = string
    default = null
  }
}

transform "remove_block_element" "telemetry_location_nullable" {
  for_each             = local.telemetry_location_exists && local.location_exists && try(data.variable.telemetry_location.result["telemetry_location"].nullable, null) == false ? toset([1]) : toset([])
  target_block_address = "variable.telemetry_location"
  paths                = ["nullable"]
  depends_on           = [transform.update_in_place.telemetry_location_with_location]
}

transform "update_in_place" "telemetry_location_without_location" {
  for_each             = local.telemetry_location_exists && !local.location_exists ? toset([1]) : toset([])
  target_block_address = "variable.telemetry_location"
  asraw {
    type     = string
    default  = "westus2"
    nullable = false
  }
}

transform "remove_block" "azurerm_client_config" {
  for_each             = local.azurerm_client_exists ? toset([1]) : toset([])
  target_block_address = "data.azurerm_client_config.telemetry"
}

transform "new_block" "azapi_client_config" {
  for_each       = !local.azapi_client_exists ? toset([1]) : toset([])
  new_block_type = "data"
  labels         = ["azapi_client_config", "telemetry"]
  filename       = "main.telemetry.tf"
  asraw {
    count = var.enable_telemetry ? 1 : 0
  }
}

transform "update_in_place" "azapi_client_config" {
  for_each             = local.azapi_client_exists ? toset([1]) : toset([])
  target_block_address = "data.azapi_client_config.telemetry"
  asraw {
    count = var.enable_telemetry ? 1 : 0
  }
}

transform "remove_block" "modtm_module_source" {
  for_each             = local.modtm_module_source_exists ? toset([1]) : toset([])
  target_block_address = "data.modtm_module_source.telemetry"
}

transform "remove_block" "modtm_telemetry" {
  for_each             = local.modtm_telemetry_exists ? toset([1]) : toset([])
  target_block_address = "resource.modtm_telemetry.telemetry"
}

transform "regex_replace_expression" "legacy_telemetry_references" {
  for_each     = local.modtm_telemetry_exists ? toset([1]) : toset([])
  regex       = "modtm_telemetry[.]telemetry"
  replacement = "azapi_resource.telemetry"
  depends_on  = [transform.remove_block.modtm_telemetry]
}

transform "remove_block" "random_uuid" {
  for_each             = local.random_uuid_exists ? toset([1]) : toset([])
  target_block_address = "resource.random_uuid.telemetry"
}

transform "new_block" "forget_modtm_telemetry" {
  for_each       = local.modtm_telemetry_exists ? toset([1]) : toset([])
  new_block_type = "removed"
  filename       = "main.telemetry.tf"
  asraw {
    from = modtm_telemetry.telemetry
    lifecycle {
      destroy = false
    }
  }
  depends_on = [transform.regex_replace_expression.legacy_telemetry_references]
}

transform "new_block" "forget_random_uuid" {
  for_each       = local.random_uuid_exists ? toset([1]) : toset([])
  new_block_type = "removed"
  filename       = "main.telemetry.tf"
  asraw {
    from = random_uuid.telemetry
    lifecycle {
      destroy = false
    }
  }
  depends_on = [transform.remove_block.random_uuid]
}

transform "remove_block_element" "drop_modtm_provider" {
  for_each             = local.modtm_provider_exists && length(local.other_modtm_resources) == 0 && length(local.other_modtm_data) == 0 ? toset([1]) : toset([])
  target_block_address = "terraform"
  paths                = ["required_providers.modtm"]
  depends_on = [
    transform.remove_block.modtm_module_source,
    transform.remove_block.modtm_telemetry,
  ]
}

transform "remove_block_element" "drop_unused_random_provider" {
  for_each             = local.random_uuid_exists && local.random_provider_exists && length(local.other_random_resources) == 0 && length(local.other_random_data) == 0 ? toset([1]) : toset([])
  target_block_address = "terraform"
  paths                = ["required_providers.random"]
  depends_on           = [transform.remove_block.random_uuid]
}

transform "ensure_local" "main_location" {
  for_each           = !local.main_location_exists ? toset([1]) : toset([])
  name               = "main_location"
  fallback_file_name = "main.telemetry.tf"
  value_as_string    = local.main_location_expression
}

transform "update_in_place" "main_location" {
  for_each             = local.main_location_exists ? toset([1]) : toset([])
  target_block_address = "local.main_location"
  asstring {
    main_location = local.main_location_expression
  }
}

transform "new_block" "telemetry_locals" {
  for_each       = !local.avm_metadata_exists ? toset([1]) : toset([])
  new_block_type = "locals"
  filename       = "main.telemetry.tf"
  asraw {
    avm_metadata                = jsondecode(file("${path.module}/metadata.json"))
    avm_telemetry_manifest_path = "${path.root}/.terraform/modules/modules.json"
    avm_telemetry_modules       = fileexists(local.avm_telemetry_manifest_path) ? jsondecode(file(local.avm_telemetry_manifest_path)).Modules : []
    avm_telemetry_module_entry  = try(one([for module in local.avm_telemetry_modules : module if module.Dir == path.module]), null)
    avm_module_version          = try(local.avm_telemetry_module_entry.Version, "")
    avm_module_source           = try(local.avm_telemetry_module_entry.Source, "")
    avm_module_source_type = (
      can(regex("^registry[.]terraform[.]io/", local.avm_module_source)) ? "terraform-registry" :
      can(regex("^registry[.]opentofu[.]org/", local.avm_module_source)) ? "opentofu-registry" :
      can(regex("^git::", local.avm_module_source)) ? "git" :
      "other"
    )
  }
}

transform "new_block" "terraform_data" {
  for_each       = !local.terraform_data_exists ? toset([1]) : toset([])
  new_block_type = "resource"
  labels         = ["terraform_data", "telemetry"]
  filename       = "main.telemetry.tf"
  asraw {
    count = var.enable_telemetry ? 1 : 0
  }
}

transform "update_in_place" "terraform_data" {
  for_each             = local.terraform_data_exists ? toset([1]) : toset([])
  target_block_address = "resource.terraform_data.telemetry"
  asraw {
    count = var.enable_telemetry ? 1 : 0
  }
}

transform "new_block" "azapi_resource" {
  for_each       = !local.azapi_resource_exists ? toset([1]) : toset([])
  new_block_type = "resource"
  labels         = ["azapi_resource", "telemetry"]
  filename       = "main.telemetry.tf"
  asraw {
    count     = var.enable_telemetry ? 1 : 0
    type      = "Microsoft.Resources/deployments@2025-04-01"
    name      = "${local.avm_metadata.telemetryIdPrefix}.${substr(sha1(terraform_data.telemetry[0].id), 0, 4)}"
    parent_id = one(data.azapi_client_config.telemetry).subscription_resource_id
    location  = local.main_location
    response_export_values = []
    tags = {
      avm_module_version        = local.avm_module_version
      avm_module_source_type    = local.avm_module_source_type
      avm_module_canonical_type = local.avm_metadata.canonicalType
      avm_apply_id             = plantimestamp()
    }
    body = {
      properties = {
        mode = "Incremental"
        template = {
          "$schema"      = "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#"
          contentVersion = "1.0.0.0"
          resources      = []
        }
      }
    }
  }
}

transform "update_in_place" "azapi_resource" {
  for_each             = local.azapi_resource_exists ? toset([1]) : toset([])
  target_block_address = "resource.azapi_resource.telemetry"
  asraw {
    count     = var.enable_telemetry ? 1 : 0
    type      = "Microsoft.Resources/deployments@2025-04-01"
    name      = "${local.avm_metadata.telemetryIdPrefix}.${substr(sha1(terraform_data.telemetry[0].id), 0, 4)}"
    parent_id = one(data.azapi_client_config.telemetry).subscription_resource_id
    location  = local.main_location
    response_export_values = []
    tags = {
      avm_module_version        = local.avm_module_version
      avm_module_source_type    = local.avm_module_source_type
      avm_module_canonical_type = local.avm_metadata.canonicalType
      avm_apply_id             = plantimestamp()
    }
    body = {
      properties = {
        mode = "Incremental"
        template = {
          "$schema"      = "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#"
          contentVersion = "1.0.0.0"
          resources      = []
        }
      }
    }
  }
}
