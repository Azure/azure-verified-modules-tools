output "example_resource_counts" {
  description = "The resource counts used to verify this mock module through a test wrapper."
  value = {
    resource_groups           = length(azapi_resource.example_rg)
    singleton_resource_groups = length(azapi_resource.example_rg_singleton)
    telemetry                 = length(azapi_resource.telemetry)
  }
}

output "example_resource_ids" {
  description = "The IDs of the example resources created by the module, keyed by example_keys."
  value       = local.example_resource_ids
}

output "required_interface_values" {
  description = "The required AzAPI interface values exposed by this mock module."
  value = {
    ignore_body_changes                     = var.ignore_body_changes
    private_endpoints_manage_dns_zone_group = var.private_endpoints_manage_dns_zone_group
    retry                                   = var.retry
    timeouts                                = var.timeouts
  }
}

output "resource_id" {
  description = "The ID of the resource created by the module."
  value       = try(values(azapi_resource.example_rg)[0].id, null)
}

output "resource_ids" {
  deprecated  = "Use the example_resource_ids output instead."
  description = "Deprecated alias for example_resource_ids."
  value       = local.example_resource_ids
}

output "subscription_id" {
  description = "The ID of the subscription the module is deployed to."
  sensitive   = true
  value       = data.azapi_client_config.this.subscription_id
}
