module "azure" {
  source = "./modules/azure"
  count  = var.repository_creation_mode_enabled ? 0 : 1

  management_group_id     = var.management_group_id
  github_repository_owner = var.github_repository_owner
  github_repository_name  = var.github_repository_name
  github_repository_environment_names = [
    var.github_repository_pr_check_environment_name,
    var.github_repository_integration_test_environment_name,
    var.github_repository_examples_test_environment_name,
  ]
  identity_resource_group_name = var.identity_resource_group_name
  location                     = var.location
  github_job_workflow_ref      = var.github_job_workflow_ref
  github_organization_id       = module.github.organization_id
  github_repository_id         = module.github.repository_id
  is_protected_repo            = var.is_protected_repo
}

module "github" {
  source = "./modules/github"

  repository_creation_mode_enabled                    = var.repository_creation_mode_enabled
  github_repository_owner                             = var.github_repository_owner
  github_repository_name                              = var.github_repository_name
  github_repository_pr_check_environment_name         = var.github_repository_pr_check_environment_name
  github_repository_integration_test_environment_name = var.github_repository_integration_test_environment_name
  github_repository_examples_test_environment_name    = var.github_repository_examples_test_environment_name
  github_repository_no_approval_environment_name      = var.github_repository_no_approval_environment_name
  is_protected_repo                                   = var.is_protected_repo
  bypass_ruleset_for_approval_enabled                 = true
  github_teams                                        = var.github_teams
  pull_request_bypass_teams                           = var.pull_request_bypass_teams
  github_avm_app_id                                   = var.github_avm_app_id
  labels                                              = local.labels
  arm_client_id                                       = local.test_settings.client_id
  arm_tenant_id                                       = local.test_settings.tenant_id
  test_subscription_ids                               = local.test_settings.test_subscription_ids
  module_id                                           = var.module_id
  module_name                                         = var.module_name
  copilot_agent_firewall_allow_list                   = var.github_copilot_agent_firewall_allow_list
  copilot_agent_firewall_allow_list_variable_name     = var.github_copilot_agent_firewall_allow_list_variable_name
  topics                                              = var.topics
}

import {
  id = var.github_repository_name
  to = module.github.github_repository.this
}
