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
  description = "The IDs of the example resources created by the module, keyed by example_keys."
  value       = { for k, r in azapi_resource.example_rg : k => r.id }
}

output "subscription_id" {
  description = "The ID of the subscription the module is deployed to."
  sensitive   = true
  value       = data.azapi_client_config.this.subscription_id
}
