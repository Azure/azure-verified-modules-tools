module "azure" {
  source = "../terraform/modules/azure"

  management_group_id          = var.management_group_id
  github_repository_owner      = var.github_repository_owner
  github_repository_name       = var.github_repository_name
  identity_resource_group_name = var.identity_resource_group_name
  github_repository_environment_names = [
    "pr-check",
    "integration-test",
    "examples-test",
  ]
  location                      = var.location
  github_job_workflow_ref       = var.github_job_workflow_ref
  github_organization_id        = var.github_organization_id
  github_repository_id          = var.github_repository_id
  repository_sync_repository_id = var.repository_sync_repository_id
  is_protected_repo             = true
  bami_group_settings = {
    tenant_id                     = var.tenant_id
    controller_client_id          = var.controller_client_id
    entra_readers_group_id        = var.entra_readers_group_id
    test_identity_owners_group_id = var.test_identity_owners_group_id
    fabric_admins_group_id        = var.fabric_admins_group_id
    fabric_admin_apis             = var.fabric_admin_apis
  }
}
