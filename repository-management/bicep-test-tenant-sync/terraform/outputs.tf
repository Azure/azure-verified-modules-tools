output "test_identities" {
  sensitive = true
  value = {
    for path, identity in module.bicep : path => {
      client_id            = identity.client_id
      tenant_id            = identity.tenant_id
      identity_resource_id = identity.identity_resource_id
    }
  }
}

output "test_group_contract" {
  sensitive = true
  value = {
    for path, identity in module.bicep : path => identity.test_group_contract
  }
}
