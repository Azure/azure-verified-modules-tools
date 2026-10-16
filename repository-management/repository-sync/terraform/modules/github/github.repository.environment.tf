locals {
  environment_approval_team_ids = [for k, v in var.github_teams : data.github_team.this[k].id if v.environment_approval]

  test_environments = var.repository_creation_mode_enabled ? {} : {
    pr_check         = var.github_repository_pr_check_environment_name
    integration_test = var.github_repository_integration_test_environment_name
    examples_test    = var.github_repository_examples_test_environment_name
  }
}

# Preserve existing resource addresses and environment names for OIDC federation.
resource "github_repository_environment" "approval" {
  for_each = local.test_environments

  environment         = each.value
  repository          = github_repository.this.name
  can_admins_bypass   = true
  prevent_self_review = false
  dynamic "reviewers" {
    for_each = each.key == "pr_check" ? [] : [local.environment_approval_team_ids]
    content {
      teams = reviewers.value
    }
  }
}

# This environment is used for jobs that do not require approval (or auth).
# It is also referenced by `github.actions_oidc.tf` via the `context` claim
# (which expands to `environment:<name>`) so that jobs running in this
# environment still get an OIDC token under the customized subject template.
resource "github_repository_environment" "no_approval" {
  environment = var.github_repository_no_approval_environment_name
  repository  = github_repository.this.name
}
