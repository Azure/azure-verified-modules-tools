module "test" {
  source = "../../"
  providers = {
    azapi = azapi
  }

  location         = "westus3"
  enable_telemetry = var.enable_telemetry
}
