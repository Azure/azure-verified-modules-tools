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
  repository_creation_mode_enabled                           = false
  arm_client_id                                              = "20000000-0000-4000-8000-000000000001"
  arm_tenant_id                                              = "20000000-0000-4000-8000-000000000002"
  test_subscription_ids                                      = []
  github_repository_owner                                    = "Azure"
  github_repository_name                                     = "terraform-azurerm-avm-ptn-example-repo"
  module_id                                                  = "avm-ptn-example-repo"
  module_name                                                = "Example"
  github_repository_pr_check_environment_name                = "pr-check"
  github_repository_integration_test_environment_name        = "integration-test"
  github_repository_examples_test_environment_name           = "examples-test"
  github_repository_examples_test_execution_environment_name = "examples-test-execution"
  github_repository_no_approval_environment_name             = "no-approval"
  labels                                                     = {}
  is_protected_repo                                          = true
  bypass_ruleset_for_approval_enabled                        = true
  github_avm_app_id                                          = "1049636"
  copilot_agent_firewall_allow_list_variable_name            = "COPILOT_AGENT_FIREWALL_ALLOW_LIST_ADDITIONS"
  copilot_agent_firewall_allow_list                          = []
  github_teams                                               = {}
  pull_request_bypass_teams                                  = []
}

run "release_metadata_check_is_not_required_by_default" {
  command = plan

  module {
    source = "./modules/github"
  }

  assert {
    condition     = length(github_repository_ruleset.main[0].rules[0].required_status_checks) == 0
    error_message = "The main ruleset must not require status checks unless the release-metadata check is required."
  }
}

run "required_release_metadata_check_is_pinned_to_github_actions" {
  command = plan

  module {
    source = "./modules/github"
  }

  variables {
    release_metadata_check_required = true
  }

  assert {
    condition = (
      length(github_repository_ruleset.main[0].rules[0].required_status_checks) == 1 &&
      github_repository_ruleset.main[0].rules[0].required_status_checks[0].strict_required_status_checks_policy == false &&
      length(github_repository_ruleset.main[0].rules[0].required_status_checks[0].required_check) == 1 &&
      one(github_repository_ruleset.main[0].rules[0].required_status_checks[0].required_check).context == "release-metadata / Validate" &&
      one(github_repository_ruleset.main[0].rules[0].required_status_checks[0].required_check).integration_id == 15368
    )
    error_message = "The required release-metadata check must use the exact reusable workflow context and come only from the GitHub Actions app."
  }

  assert {
    condition = (
      length(github_repository_ruleset.main[0].bypass_actors) == 1 &&
      github_repository_ruleset.main[0].bypass_actors[0].actor_type == "Integration" &&
      github_repository_ruleset.main[0].bypass_actors[0].bypass_mode == "pull_request"
    )
    error_message = "Requiring the release-metadata check must keep the App pull request bypass unchanged."
  }

  assert {
    condition = (
      github_repository_ruleset.main[0].rules[0].pull_request[0].require_code_owner_review &&
      github_repository_ruleset.main[0].rules[0].pull_request[0].required_approving_review_count == 1
    )
    error_message = "Requiring the release-metadata check must keep the existing pull request rules."
  }
}
