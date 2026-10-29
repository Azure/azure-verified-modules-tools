# Shared Azure auth values are stored at repository scope so they can be
# consumed by any environment (and any new environment added in future)
# without duplicating per-environment secrets.
resource "github_actions_secret" "arm_tenant_id" {
  count       = var.repository_creation_mode_enabled ? 0 : 1
  repository  = github_repository.this.name
  secret_name = "ARM_TENANT_ID"
  value       = var.arm_tenant_id
}

resource "github_actions_secret" "arm_client_id" {
  count       = var.repository_creation_mode_enabled ? 0 : 1
  repository  = github_repository.this.name
  secret_name = "ARM_CLIENT_ID"
  value       = var.arm_client_id
}

resource "github_actions_secret" "test_subscription_ids" {
  count       = var.repository_creation_mode_enabled ? 0 : 1
  repository  = github_repository.this.name
  secret_name = "TEST_SUBSCRIPTION_IDS"
  value       = jsonencode(var.test_subscription_ids)
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
