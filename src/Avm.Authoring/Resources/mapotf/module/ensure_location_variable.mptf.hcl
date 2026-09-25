data "resource" "azure_resources" {}

data "variable" "location" {
  name = "location"
}

locals {
  has_azure_resources = length([
    for resource_type, resources in data.resource.azure_resources.result : resource_type
    if length(resources) > 0 && (
      startswith(resource_type, "azapi_") ||
      startswith(resource_type, "azurerm_") ||
      startswith(resource_type, "azuread_")
    )
  ]) > 0
  location_exists = length(data.variable.location.result) == 1
}

transform "new_block" "location" {
  for_each       = local.has_azure_resources && !local.location_exists ? toset([1]) : toset([])
  new_block_type = "variable"
  labels         = ["location"]
  filename       = "variables.tf"
  asraw {
    type        = string
    description = "The Azure region for this module's resources or telemetry deployment."
    nullable    = false
  }
}
