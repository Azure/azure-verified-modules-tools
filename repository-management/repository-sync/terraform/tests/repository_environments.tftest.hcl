mock_provider "github" {}

override_data {
  target = data.github_organization.this
  values = {
    id = "6844498"
  }
}

override_data {
  target = data.github_team.this["approvers"]
  values = {
    id = "501"
  }
}

override_data {
  target = data.github_team.this["additional-approvers"]
  values = {
    id = "502"
  }
}

override_data {
  target = data.github_team.this["readers"]
  values = {
    id = "503"
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
  pull_request_bypass_teams                           = []
  is_protected_repo                                   = true
  bypass_ruleset_for_approval_enabled                 = true
  github_avm_app_id                                   = "1049636"
  copilot_agent_firewall_allow_list_variable_name     = "COPILOT_AGENT_FIREWALL_ALLOW_LIST_ADDITIONS"
  copilot_agent_firewall_allow_list                   = []
  github_teams = {
    approvers = {
      slug                         = "avm-approvers"
      repository_access_permission = "push"
      environment_approval         = true
    }
    additional-approvers = {
      slug                         = "avm-additional-approvers"
      repository_access_permission = "push"
      environment_approval         = true
    }
    readers = {
      slug                         = "avm-readers"
      repository_access_permission = "triage"
      environment_approval         = false
    }
  }
}

run "pr_check_retains_its_environment_without_reviewers" {
  command = plan

  module {
    source = "./modules/github"
  }

  assert {
    condition     = toset(keys(github_repository_environment.approval)) == toset(["examples_test", "integration_test", "pr_check"])
    error_message = "The three existing test environment resource addresses must remain unchanged."
  }

  assert {
    condition = (
      github_repository_environment.approval["pr_check"].environment == "pr-check" &&
      length(github_repository_environment.approval["pr_check"].reviewers) == 0
    )
    error_message = "PR check must retain its OIDC environment without a reviewer gate."
  }

  assert {
    condition = alltrue([
      for key in ["integration_test", "examples_test"] : (
        length(github_repository_environment.approval[key].reviewers) == 1 &&
        toset(one(github_repository_environment.approval[key].reviewers).teams) == toset([501, 502]) &&
        github_repository_environment.approval[key].can_admins_bypass &&
        !github_repository_environment.approval[key].prevent_self_review
      )
    ])
    error_message = "Integration and e2e must retain exactly the configured approval teams and existing bypass/self-review settings."
  }

  assert {
    condition = (
      github_repository_environment.no_approval.environment == "no-approval" &&
      length(github_repository_environment.no_approval.reviewers) == 0
    )
    error_message = "Subscription selection must remain independent of environment approval."
  }

  assert {
    condition = github_actions_repository_oidc_subject_claim_customization_template.this[0].include_claim_keys == tolist([
      "repository_owner_id", "repository_id", "context", "job_workflow_ref"
    ])
    error_message = "The OIDC subject contract must not change when removing PR check reviewers."
  }
}

run "custom_names_preserve_the_same_approval_split" {
  command = plan

  module {
    source = "./modules/github"
  }

  variables {
    github_repository_pr_check_environment_name         = "custom-pr-check"
    github_repository_integration_test_environment_name = "custom-integration"
    github_repository_examples_test_environment_name    = "custom-e2e"
  }

  assert {
    condition = (
      github_repository_environment.approval["pr_check"].environment == "custom-pr-check" &&
      length(github_repository_environment.approval["pr_check"].reviewers) == 0 &&
      github_repository_environment.approval["integration_test"].environment == "custom-integration" &&
      github_repository_environment.approval["examples_test"].environment == "custom-e2e" &&
      alltrue([
        for key in ["integration_test", "examples_test"] :
        toset(one(github_repository_environment.approval[key].reviewers).teams) == toset([501, 502])
      ])
    )
    error_message = "Approval must follow each job's role, not a hard-coded environment name."
  }
}

run "creation_mode_still_omits_test_environments" {
  command = plan

  module {
    source = "./modules/github"
  }

  variables {
    repository_creation_mode_enabled = true
  }

  assert {
    condition = (
      length(github_repository_environment.approval) == 0 &&
      length(github_actions_repository_oidc_subject_claim_customization_template.this) == 0 &&
      github_repository_environment.no_approval.environment == "no-approval" &&
      length(github_repository_environment.no_approval.reviewers) == 0
    )
    error_message = "Creation mode must retain its existing environment and OIDC provisioning behavior."
  }
}
