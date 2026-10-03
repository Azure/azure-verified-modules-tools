output "client_id" {
  value = azapi_resource.identity.output.properties.clientId
}

output "tenant_id" {
  value = data.azapi_client_config.current.tenant_id
}

output "identity_resource_id" {
  value = azapi_resource.identity.id
}

output "test_group_contract" {
  description = "Observed provider identifiers and configured group names/IDs, without shared membership or owner lists."
  value = {
    azure_context = {
      tenant_id       = data.azapi_client_config.current.tenant_id
      subscription_id = data.azapi_client_config.current.subscription_id
    }
    graph_context = {
      tenant_id = data.azuread_client_config.current.tenant_id
      client_id = data.azuread_client_config.current.client_id
      object_id = data.azuread_client_config.current.object_id
    }
    groups = {
      for name, group in data.azuread_group.test_permissions : name => {
        object_id        = group.object_id
        display_name     = group.display_name
        security_enabled = group.security_enabled
      }
    }
  }
}
