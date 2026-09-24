module "test" {
  source = "../../"

  location                 = "westus3"
  create_example_resources = false
  enable_telemetry         = var.enable_telemetry
  telemetry_location       = var.telemetry_location
}

output "resource_ids" {
  description = "The example resource IDs accessed through the deprecated compatibility output."
  value       = module.test.resource_ids
}
