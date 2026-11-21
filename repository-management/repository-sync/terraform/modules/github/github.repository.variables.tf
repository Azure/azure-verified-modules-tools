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

resource "github_actions_variable" "azure_local_environment_lock" {
  count         = var.azure_local_environment_lock == null ? 0 : 1
  repository    = github_repository.this.name
  variable_name = "AVM_AZURE_LOCAL_ENVIRONMENT_LOCK"
  value         = jsonencode(var.azure_local_environment_lock)
}

resource "github_actions_variable" "azure_local_environment_mode" {
  count         = var.azure_local_environment_mode == null ? 0 : 1
  repository    = github_repository.this.name
  variable_name = "AVM_AZURE_LOCAL_ENVIRONMENT_MODE"
  value         = var.azure_local_environment_mode
}
