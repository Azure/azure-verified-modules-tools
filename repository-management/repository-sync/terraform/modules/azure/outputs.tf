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
  description = "Nonsecret observed provider and group evidence; null for legacy identities."
  value = var.bami_group_settings == null ? null : {
    azure_context = {
      tenant_id       = data.azapi_client_config.current.tenant_id
      subscription_id = data.azapi_client_config.current.subscription_id
    }
    graph_context = {
      tenant_id = data.azuread_client_config.bami[0].tenant_id
      client_id = data.azuread_client_config.bami[0].client_id
      object_id = data.azuread_client_config.bami[0].object_id
    }
    groups = {
      for name, group in merge({ entra_readers = data.azuread_group.entra_readers }, data.azuread_group.test_permissions) : name => {
        object_id               = group.object_id
        display_name            = group.display_name
        security_enabled        = group.security_enabled
        mail_enabled            = group.mail_enabled
        types                   = group.types
        onpremises_sync_enabled = group.onpremises_sync_enabled
      }
    }
  }
}
