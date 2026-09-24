data "azapi_client_config" "telemetry" {
  count = var.enable_telemetry ? 1 : 0
}

locals {
  main_location = var.telemetry_location != null ? var.telemetry_location : var.location
}

resource "azapi_resource" "telemetry" {
  count = var.enable_telemetry ? 1 : 0

  location  = local.main_location
  name      = "${local.avm_metadata.telemetryIdPrefix}.${substr(sha1(terraform_data.telemetry[0].id), 0, 4)}"
  parent_id = one(data.azapi_client_config.telemetry).subscription_resource_id
  type      = "Microsoft.Resources/deployments@2025-04-01"
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
  tags = {
    avm_module_version        = local.avm_module_version
    avm_module_source_type    = local.avm_module_source_type
    avm_module_canonical_type = local.avm_metadata.canonicalType
    avm_apply_id              = plantimestamp()
  }
}

resource "terraform_data" "telemetry" {
  count = var.enable_telemetry ? 1 : 0
}

locals {
  avm_module_source = try(local.avm_telemetry_module_entry.Source, "")
  avm_module_source_type = (
    can(regex("^registry[.]terraform[.]io/", local.avm_module_source)) ? "terraform-registry" :
    can(regex("^registry[.]opentofu[.]org/", local.avm_module_source)) ? "opentofu-registry" :
    can(regex("^git::", local.avm_module_source)) ? "git" :
    "other"
  )
  avm_metadata                = jsondecode(file("${path.module}/metadata.json"))
  avm_telemetry_manifest_path = "${path.root}/.terraform/modules/modules.json"
  avm_telemetry_modules       = fileexists(local.avm_telemetry_manifest_path) ? jsondecode(file(local.avm_telemetry_manifest_path)).Modules : []
  avm_telemetry_module_entry  = try(one([for module in local.avm_telemetry_modules : module if module.Dir == path.module]), null)
  avm_module_version          = try(local.avm_telemetry_module_entry.Version, "")
}

removed {
  from = modtm_telemetry.telemetry
  lifecycle {
    destroy = false
  }
}

removed {
  from = random_uuid.telemetry
  lifecycle {
    destroy = false
  }
}
