output "test_identity" {
  value = {
    tenant_id            = module.azure.tenant_id
    client_id            = module.azure.client_id
    identity_resource_id = module.azure.identity_resource_id
    repository_id        = var.github_repository_id
    repository_owner_id  = var.github_organization_id
  }
}
