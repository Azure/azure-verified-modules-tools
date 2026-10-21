module "region_lookup" {
  source  = "Azure/avm-utl-regions/azurerm"
  version = "0.13.0"

  location         = var.location
  enable_telemetry = false
  is_recommended   = true
}

module "names" {
  source  = "Azure/avm-utl-naming/azure"
  version = "0.2.0"

  suffix        = ["compatibility"]
  unique-length = 8
}

module "test" {
  source = "../../"
  providers = {
    azapi = azapi.owner

  }

  location                 = "westus3"
  create_example_resources = false
  enable_telemetry         = var.enable_telemetry
}

output "legacy_name" {
  description = "The deprecated named output remains supported in modern mode."
  value       = module.names.resource_group.name
}

output "resource_ids" {
  description = "The example resource IDs accessed through the deprecated compatibility output."
  value       = module.test.resource_ids
}
