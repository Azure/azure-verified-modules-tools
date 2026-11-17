resource "github_repository_ruleset" "main" {
  count       = var.repository_creation_mode_enabled ? 0 : 1
  name        = "Azure Verified Modules"
  repository  = github_repository.this.name
  target      = "branch"
  enforcement = "active"

  dynamic "bypass_actors" {
    for_each = var.bypass_ruleset_for_approval_enabled ? [1] : []
    content {
      actor_id    = var.github_avm_app_id
      actor_type  = "Integration"
      bypass_mode = "pull_request"
    }
  }

  dynamic "bypass_actors" {
    for_each = toset(var.pull_request_bypass_teams)
    content {
      actor_id    = data.github_team.this[bypass_actors.value].id
      actor_type  = "Team"
      bypass_mode = "pull_request"
    }
  }

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    creation                = true
    deletion                = true
    required_linear_history = true
    non_fast_forward        = true

    dynamic "required_status_checks" {
      for_each = var.terraform_pr_test_gates_enabled ? [1] : []
      content {
        strict_required_status_checks_policy = true
        do_not_enforce_on_create              = false
        required_check {
          context        = "run managed workflow / Terraform validation gate"
          integration_id = 15368
        }
        required_check {
          context        = "run managed workflow / Terraform required E2E gate"
          integration_id = 15368
        }
      }
    }

    pull_request {
      allowed_merge_methods             = ["squash"]
      dismiss_stale_reviews_on_push     = true
      require_code_owner_review         = true
      required_approving_review_count   = var.is_protected_repo ? 1 : 0
      require_last_push_approval        = var.is_protected_repo
      required_review_thread_resolution = true
    }
  }
}

resource "github_repository_ruleset" "tag_deny_non_v" {
  count       = var.repository_creation_mode_enabled ? 0 : 1
  name        = "Only allow v tags"
  repository  = github_repository.this.name
  target      = "tag"
  enforcement = "active"

  rules {
    creation = true
    update   = true
  }

  conditions {
    ref_name {
      include = ["~ALL"]
      exclude = ["refs/tags/v[0-9]*.[0-9]*.[0-9]*"]
    }
  }
}

resource "github_repository_ruleset" "tag_prevent_v1_plus" {
  count       = var.repository_creation_mode_enabled ? 0 : 1
  name        = "Restrict v1+ release tags"
  repository  = github_repository.this.name
  target      = "tag"
  enforcement = "active"

  dynamic "bypass_actors" {
    for_each = toset([for name, team in var.github_teams : name if team.slug == "azure-verified-modules-engineering-owners"])
    content {
      actor_id    = data.github_team.this[bypass_actors.value].id
      actor_type  = "Team"
      bypass_mode = "always"
    }
  }

  rules {
    creation = true
  }

  conditions {
    ref_name {
      include = ["refs/tags/v[0-9]*.[0-9]*.[0-9]*"]
      exclude = ["refs/tags/v0.[0-9]*.[0-9]*"]
    }
  }
}

resource "github_repository_ruleset" "tag_prevent_delete_version_tags" {
  count       = var.repository_creation_mode_enabled ? 0 : 1
  name        = "Must not delete/update version tags"
  repository  = github_repository.this.name
  target      = "tag"
  enforcement = "active"

  rules {
    update           = true
    deletion         = true
    non_fast_forward = true
  }

  conditions {
    ref_name {
      include = ["refs/tags/v[0-9]*.[0-9]*.[0-9]*"]
      exclude = []
    }
  }
}

moved {
  from = github_repository_ruleset.tag_deny_non_v
  to   = github_repository_ruleset.tag_deny_non_v[0]
}

moved {
  from = github_repository_ruleset.tag_prevent_delete_version_tags
  to   = github_repository_ruleset.tag_prevent_delete_version_tags[0]
}
