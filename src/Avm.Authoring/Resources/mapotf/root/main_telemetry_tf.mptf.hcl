locals {
  sync_main_telemetry_tf = true
}

data "variable" enable_telemetry {
  name = "enable_telemetry"
}

locals {
  var_dot_enable_telemetry_exists = try(data.variable.enable_telemetry.result["enable_telemetry"] != null, false)
}

transform "new_block" new_enable_telemetry_variable {
  for_each       = local.sync_main_telemetry_tf && !local.var_dot_enable_telemetry_exists ? toset([1]) : toset([])
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

transform "update_in_place" enable_telemetry_variable {
  for_each             = local.sync_main_telemetry_tf && local.var_dot_enable_telemetry_exists ? toset([1]) : toset([])
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
  depends_on = [
    transform.new_block.new_enable_telemetry_variable
  ]
}

data "data" "azurerm_client_config" {
  data_source_type = "azurerm_client_config"
}

locals {
  data_azurerm_client_config_telemetry_exists = try(data.data.azurerm_client_config.result["azurerm_client_config"].telemetry.mptf != null, false)
}

transform "remove_block" azurerm_client_config {
  for_each             = local.sync_main_telemetry_tf && local.data_azurerm_client_config_telemetry_exists ? toset([1]) : toset([])
  target_block_address = "data.azurerm_client_config.telemetry"
}

data "data" "azapi_client_config" {
  data_source_type = "azapi_client_config"
}

locals {
  data_azapi_client_config_telemetry_exists = try(data.data.azapi_client_config.result["azapi_client_config"].telemetry.mptf != null, false)
}

transform "new_block" azapi_client_config {
  for_each       = local.sync_main_telemetry_tf && !local.data_azapi_client_config_telemetry_exists ? toset([1]) : toset([])
  new_block_type = "data"
  labels         = ["azapi_client_config", "telemetry"]
  filename       = "main.telemetry.tf"
  asraw {
    count = var.enable_telemetry ? 1 : 0
  }
}

transform "update_in_place" azapi_client_config {
  for_each             = local.sync_main_telemetry_tf && local.data_azapi_client_config_telemetry_exists ? toset([1]) : toset([])
  target_block_address = "data.azapi_client_config.telemetry"
  asraw {
    count = var.enable_telemetry ? 1 : 0
  }
}

data "data" modtm_module_source {
  data_source_type = "modtm_module_source"
}

transform "new_block" new_modtm_module_source {
  for_each       = local.sync_main_telemetry_tf && try(data.data.modtm_module_source.result["modtm_module_source"].telemetry == null, true) ? toset([1]) : toset([])
  new_block_type = "data"
  labels         = ["modtm_module_source", "telemetry"]
  filename       = "main.telemetry.tf"
  asraw {
    count       = var.enable_telemetry ? 1 : 0
    module_path = path.module
  }
}

transform "update_in_place" modtm_module_source {
  for_each             = local.sync_main_telemetry_tf && try(data.data.modtm_module_source.result["modtm_module_source"].telemetry != null, false) ? toset([1]) : toset([])
  target_block_address = "data.modtm_module_source.telemetry"
  asraw {
    count       = var.enable_telemetry ? 1 : 0
    module_path = path.module
  }
  depends_on = [
    transform.new_block.new_modtm_module_source
  ]
}

data "resource" "random_uuid" {
  resource_type = "random_uuid"
}

transform "new_block" new_random_uuid {
  for_each       = local.sync_main_telemetry_tf && try(data.resource.random_uuid.result["random_uuid"].telemetry == null, true) ? toset([1]) : toset([])
  new_block_type = "resource"
  labels         = ["random_uuid", "telemetry"]
  filename       = "main.telemetry.tf"
  asraw {
    count = var.enable_telemetry ? 1 : 0
  }
}

transform "update_in_place" random_uuid {
  for_each             = local.sync_main_telemetry_tf && try(data.resource.random_uuid.result["random_uuid"].telemetry != null, false) ? toset([1]) : toset([])
  target_block_address = "resource.random_uuid.telemetry"
  asraw {
    count = var.enable_telemetry ? 1 : 0
  }
  depends_on = [
    transform.new_block.new_random_uuid
  ]
}

data "resource" "modtm_telemetry_telemetry" {
  resource_type = "modtm_telemetry"
}

data "variable" location {
  name = "location"
  type = "string"
}

data "resource" "modtm_telemetry" {
  resource_type = "modtm_telemetry"
}

data "local" "main_location" {
  name = "main_location"
}

locals {
  location_variable_exist                   = length(data.variable.location.result) == 1
  local_dot_main_location_exist             = length(data.local.main_location.result) == 1
  resource_modtm_telemetry_telemetry_exists = try(data.resource.modtm_telemetry_telemetry.result["modtm_telemetry"].telemetry.mptf != null, false)
}

transform "ensure_local" main_location {
  for_each           = local.sync_main_telemetry_tf && !local.local_dot_main_location_exist ? toset([1]) : toset([])
  name               = "main_location"
  fallback_file_name = "main.telemetry.tf"
  value_as_string    = local.location_variable_exist ? "var.location" : "\"unknown\""
}

locals {
  raw_telemetry_tags = <<-EOT
    merge({
      subscription_id = one(data.azapi_client_config.telemetry).subscription_id
      tenant_id       = one(data.azapi_client_config.telemetry).tenant_id
      module_source   = one(data.modtm_module_source.telemetry).module_source
      module_version  = one(data.modtm_module_source.telemetry).module_version
      random_id       = one(random_uuid.telemetry).result
    }, { location = local.main_location })
EOT
  telemetry_tags     = trim(local.raw_telemetry_tags, "\r\n")
}

transform "new_block" new_modtm_telemetry_telemetry {
  for_each       = local.sync_main_telemetry_tf && !local.resource_modtm_telemetry_telemetry_exists ? toset([1]) : toset([])
  new_block_type = "resource"
  labels         = ["modtm_telemetry", "telemetry"]
  filename       = "main.telemetry.tf"
  asstring {
    count = "var.enable_telemetry ? 1 : 0"

    tags = local.telemetry_tags
  }
}

transform "update_in_place" modtm_telemetry_telemetry {
  for_each             = local.sync_main_telemetry_tf && local.resource_modtm_telemetry_telemetry_exists ? toset([1]) : toset([])
  target_block_address = "resource.modtm_telemetry.telemetry"
  asstring {
    count = "var.enable_telemetry ? 1 : 0"

    tags = local.telemetry_tags
  }
}
