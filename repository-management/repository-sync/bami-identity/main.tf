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
  location                = var.location
  github_job_workflow_ref = var.github_job_workflow_ref
  github_organization_id  = var.github_organization_id
  github_repository_id    = var.github_repository_id
  is_protected_repo       = true
}
