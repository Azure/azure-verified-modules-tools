module "bicep" {
  for_each = var.modules
  source   = "../../repository-sync/terraform/modules/azure"

  identity_name                       = local.identity_names[each.key]
  identity_resource_group_name        = var.bami_test_settings.identity_resource_group_name
  github_repository_owner             = "Azure"
  github_repository_name              = "bicep-registry-modules"
  github_repository_environment_names = ["avm-validation"]
  github_organization_id              = var.github_organization_id
  github_repository_id                = var.github_repository_id
  repository_sync_repository_id       = var.repository_sync_repository_id
  github_job_workflow_ref             = local.job_workflow_ref
  github_workflow_ref                 = "Azure/bicep-registry-modules/.github/workflows/${replace(each.key, "/", ".")}.yml@refs/heads/main"
  location                            = var.location
  is_protected_repo                   = true
  entra_group_names                   = each.value
  expected_identity_context = {
    tenant_id            = var.bami_test_settings.tenant_id
    subscription_id      = var.bami_test_settings.admin_subscription_id
    controller_client_id = var.bami_test_settings.controller_client_id
    bicep_client_id      = var.bami_test_settings.bicep_client_id
  }
}
