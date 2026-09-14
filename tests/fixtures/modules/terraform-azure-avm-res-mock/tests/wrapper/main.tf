module "test" {
  source = "../../"

  location = var.location

  create_example_resources = var.create_example_resources
  create_mock_resources    = var.create_mock_resources
  enable_telemetry         = var.enable_telemetry
}
