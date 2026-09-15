module "test" {
  source = "../../"

  location              = "westus3"
  create_mock_resources = false
}

output "example_resource_ids" {
  description = "The example resource IDs accessed through the current output."
  value       = module.test.example_resource_ids
}
