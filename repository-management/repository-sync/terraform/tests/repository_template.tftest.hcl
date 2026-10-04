mock_provider "github" {}

override_data {
  target = data.github_organization.this
  values = {
    id = "6844498"
  }
}

override_resource {
  target = github_repository.this
  values = {
    id      = "terraform-azurerm-avm-ptn-example-repo"
    name    = "terraform-azurerm-avm-ptn-example-repo"
    repo_id = 1234
  }
}

variables {
  repository_creation_mode_enabled                    = false
  arm_client_id                                       = "20000000-0000-4000-8000-000000000001"
  arm_tenant_id                                       = "20000000-0000-4000-8000-000000000002"
  test_subscription_ids                               = []
  github_repository_owner                             = "Azure"
  github_repository_name                              = "terraform-azurerm-avm-ptn-example-repo"
  module_id                                           = "avm-ptn-example-repo"
  module_name                                         = "Example"
  github_repository_pr_check_environment_name         = "pr-check"
  github_repository_integration_test_environment_name = "integration-test"
  github_repository_examples_test_environment_name    = "examples-test"
  github_repository_no_approval_environment_name      = "no-approval"
  labels                                              = {}
  github_teams                                        = {}
  pull_request_bypass_teams                           = []
  is_protected_repo                                   = true
  bypass_ruleset_for_approval_enabled                 = true
  github_avm_app_id                                   = "1049636"
  copilot_agent_firewall_allow_list_variable_name     = "COPILOT_AGENT_FIREWALL_ALLOW_LIST_ADDITIONS"
  copilot_agent_firewall_allow_list                   = []
}

run "seed_existing_template" {
  command   = apply
  state_key = "existing-template"

  module {
    source = "./tests/fixtures/repository-template"
  }
}

run "preserve_existing_template_without_replacement" {
  command   = plan
  state_key = "existing-template"

  module {
    source = "./modules/github"
  }

  assert {
    condition     = one(github_repository.this.template).repository == "terraform-azurerm-avm-template"
    error_message = "The existing template must remain ignored, rather than removed or replacing the protected repository."
  }
}

run "omit_template_for_fresh_repository" {
  command   = plan
  state_key = "fresh-template"

  module {
    source = "./modules/github"
  }

  variables {
    repository_creation_mode_enabled = true
  }

  assert {
    condition     = length(github_repository.this.template) == 0
    error_message = "Fresh repository configuration must no longer request the redundant nested template."
  }
}
