module "azure" {
  source = "../terraform/modules/azure"

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
  entra_group_names             = var.entra_group_names
  expected_identity_context = {
    tenant_id            = var.tenant_id
    subscription_id      = var.subscription_id
    controller_client_id = var.controller_client_id
  }
}
