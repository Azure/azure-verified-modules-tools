# Retain legacy values until variable-aware callers are deployed and cleanup is verified.
removed {
  from = github_actions_secret.arm_tenant_id
  lifecycle {
    destroy = false
  }
}

removed {
  from = github_actions_secret.arm_client_id
  lifecycle {
    destroy = false
  }
}

removed {
  from = github_actions_secret.test_subscription_ids
  lifecycle {
    destroy = false
  }
}

resource "github_actions_variable" "subscription_vending_management_group_id" {
  count         = var.repository_creation_mode_enabled || var.subscription_vending_management_group_id == null ? 0 : 1
  repository    = github_repository.this.name
  variable_name = "TEST_BAMI_SUBSCRIPTION_VENDING_MANAGEMENT_GROUP_ID"
  value         = var.subscription_vending_management_group_id
}

resource "github_actions_secret" "subscription_vending_billing_scope" {
  count       = var.repository_creation_mode_enabled || var.subscription_vending_billing_scope == null ? 0 : 1
  repository  = github_repository.this.name
  secret_name = "TF_VAR_subscription_billing_scope"
  value       = var.subscription_vending_billing_scope
}

resource "github_actions_secret" "subscription_vending_management_group_id" {
  count       = var.repository_creation_mode_enabled || var.subscription_vending_management_group_id == null ? 0 : 1
  repository  = github_repository.this.name
  secret_name = "TF_VAR_subscription_management_group_id"
  value       = var.subscription_vending_management_group_id
}
