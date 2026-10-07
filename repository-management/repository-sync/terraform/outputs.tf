output "test_settings" {
  description = "Effective non-production test identity and configured subscription IDs for repository-sync plan consumers."
  value       = local.test_settings
}

output "test_identity" {
  description = "Dedicated repository identity and its GitHub federation ownership."
  value = var.repository_creation_mode_enabled || var.bami_test_settings == null ? null : {
    tenant_id            = module.bami[0].tenant_id
    client_id            = module.bami[0].client_id
    identity_resource_id = module.bami[0].identity_resource_id
    repository_id        = tostring(module.github.repository_id)
    repository_owner_id  = tostring(module.github.organization_id)
  }
}

output "test_group_contract" {
  description = "Observed provider and configured group identifiers; excludes shared membership and owner lists."
  value       = var.repository_creation_mode_enabled || var.bami_test_settings == null ? null : module.bami[0].test_group_contract
}
