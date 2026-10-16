module "region_lookup" {
  source  = "Azure/avm-utl-regions/azurerm"
  version = "0.9.2"
  providers = {
    modtm = modtm
  }

  enable_telemetry = false
  is_recommended   = true
}

module "names" {
  source  = "Azure/naming/azurerm"
  version = "0.4.2"

  suffix        = ["compatibility"]
  unique-length = 8
}

module "test" {
  source = "../../"
  providers = {
    azapi = azapi.owner
    modtm = modtm
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
