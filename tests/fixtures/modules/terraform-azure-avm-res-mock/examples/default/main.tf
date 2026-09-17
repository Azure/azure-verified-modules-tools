module "test" {
  source = "../../"

  location                 = "westus3"
  create_example_resources = false
  enable_telemetry         = false
}

output "resource_ids" {
  description = "The example resource IDs accessed through the deprecated compatibility output."
  value       = module.test.resource_ids
}
