resource "github_actions_variable" "copilot_firewall_allow_list" {
  variable_name = var.copilot_agent_firewall_allow_list_variable_name
  repository    = github_repository.this.name
  value         = join(",", var.copilot_agent_firewall_allow_list)
}

resource "github_actions_variable" "arm_tenant_id" {
  count         = var.repository_creation_mode_enabled ? 0 : 1
  repository    = github_repository.this.name
  variable_name = "ARM_TENANT_ID"
  value         = var.arm_tenant_id
}

resource "github_actions_variable" "arm_client_id" {
  count         = var.repository_creation_mode_enabled ? 0 : 1
  repository    = github_repository.this.name
  variable_name = "ARM_CLIENT_ID"
  value         = var.arm_client_id
}

resource "github_actions_variable" "test_subscription_ids" {
  count         = var.repository_creation_mode_enabled ? 0 : 1
  repository    = github_repository.this.name
  variable_name = "TEST_SUBSCRIPTION_IDS"
  value         = jsonencode(var.test_subscription_ids)
}
