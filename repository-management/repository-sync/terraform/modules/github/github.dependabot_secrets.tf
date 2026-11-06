# Dependabot configuration has no variables context, so retain its secret mirrors.
# Both namespaces use the same verified repository identity and General pool.
resource "github_dependabot_secret" "arm_tenant_id" {
  count       = var.repository_creation_mode_enabled ? 0 : 1
  repository  = github_repository.this.name
  secret_name = "ARM_TENANT_ID"
  value       = var.arm_tenant_id
}

resource "github_dependabot_secret" "arm_client_id" {
  count       = var.repository_creation_mode_enabled ? 0 : 1
  repository  = github_repository.this.name
  secret_name = "ARM_CLIENT_ID"
  value       = var.arm_client_id
}

resource "github_dependabot_secret" "test_subscription_ids" {
  count       = var.repository_creation_mode_enabled ? 0 : 1
  repository  = github_repository.this.name
  secret_name = "TEST_SUBSCRIPTION_IDS"
  value       = jsonencode(var.test_subscription_ids)
}
