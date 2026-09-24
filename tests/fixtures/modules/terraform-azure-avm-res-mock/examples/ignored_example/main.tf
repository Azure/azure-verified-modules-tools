module "test" {
  source = "../../"

  location           = "westus3"
  enable_telemetry   = var.enable_telemetry
  telemetry_location = var.telemetry_location
}
