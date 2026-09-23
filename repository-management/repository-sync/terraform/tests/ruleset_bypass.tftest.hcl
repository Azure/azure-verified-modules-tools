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
  is_protected_repo                                   = true
  bypass_ruleset_for_approval_enabled                 = true
  github_avm_app_id                                   = "1049636"
  copilot_agent_firewall_allow_list_variable_name     = "COPILOT_AGENT_FIREWALL_ALLOW_LIST_ADDITIONS"
  copilot_agent_firewall_allow_list                   = []
}

run "default_bypass_remains_app_only" {
  command = plan

  module {
    source = "./modules/github"
  }

  variables {
    github_teams              = {}
    pull_request_bypass_teams = []
  }

  assert {
    condition = (
      length(github_repository_ruleset.main[0].bypass_actors) == 1 &&
      github_repository_ruleset.main[0].bypass_actors[0].actor_type == "Integration" &&
      github_repository_ruleset.main[0].bypass_actors[0].actor_id == tonumber(var.github_avm_app_id) &&
      github_repository_ruleset.main[0].bypass_actors[0].bypass_mode == "pull_request"
    )
    error_message = "Without configured teams, only the App may bypass the main ruleset on pull requests."
  }
}

run "configured_teams_bypass_pull_requests_only" {
  command = plan

  module {
    source = "./modules/github"
  }

  variables {
    github_teams = {
      "azure-verified-modules-engineering-owners" = {
        slug                         = "azure-verified-modules-engineering-owners"
        repository_access_permission = "push"
      }
      "another-owners" = {
        slug                         = "another-owners"
        repository_access_permission = "push"
      }
    }
    pull_request_bypass_teams = ["azure-verified-modules-engineering-owners", "another-owners"]
  }

  override_data {
    target = data.github_team.this["azure-verified-modules-engineering-owners"]
    values = {
      id = "501"
    }
  }

  override_data {
    target = data.github_team.this["another-owners"]
    values = {
      id = "502"
    }
  }

  assert {
    condition = (
      length(github_repository_ruleset.main[0].bypass_actors) == 3 &&
      length([for actor in github_repository_ruleset.main[0].bypass_actors : actor if actor.actor_type == "Integration" && actor.actor_id == tonumber(var.github_avm_app_id)]) == 1 &&
      length([for actor in github_repository_ruleset.main[0].bypass_actors : actor if actor.actor_type == "Team"]) == 2 &&
      contains([for actor in github_repository_ruleset.main[0].bypass_actors : actor.actor_id if actor.actor_type == "Team"], 501) &&
      contains([for actor in github_repository_ruleset.main[0].bypass_actors : actor.actor_id if actor.actor_type == "Team"], 502) &&
      alltrue([for actor in github_repository_ruleset.main[0].bypass_actors : actor.bypass_mode == "pull_request"])
    )
    error_message = "Only the App and the two configured team IDs may bypass the main ruleset, and only on pull requests."
  }
}
