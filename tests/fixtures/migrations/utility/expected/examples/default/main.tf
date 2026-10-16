module "region_lookup" {
  source  = "Azure/avm-utl-regions/azurerm"
  version = "0.13.0"
  providers = {


    azapi = azapi
  }

  location         = var.location
  enable_telemetry = false
  is_recommended   = true
}

module "names" {
  source  = "Azure/avm-utl-naming/azure"
  version = "0.2.0"

  legacy_mode   = true
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
  description = "The original naming output remains supported through legacy mode."
  value       = module.names.resource_group.name
}

output "resource_ids" {
  description = "The example resource IDs accessed through the deprecated compatibility output."
  value       = module.test.resource_ids
}
