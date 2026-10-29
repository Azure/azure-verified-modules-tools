variable "repository_creation_mode_enabled" {
  type        = bool
  description = "Whether we are running in repository creation mode."
}

variable "arm_client_id" {
  type        = string
  description = "Client ID of the service principal to use for ARM operations."
}

variable "arm_tenant_id" {
  type        = string
  description = "Tenant of the service principal to use for ARM operations."
}

variable "test_subscription_ids" {
  type = list(object({
    name = string
    id   = string
  }))
  description = "List of subscription IDs to use for testing."
}

variable "subscription_vending_management_group_id" {
  type        = string
  description = "Optional subscription-vending management group identifier for the selected repository."
  default     = null
  nullable    = true
}

variable "subscription_vending_billing_scope" {
  type        = string
  description = "Optional invoice-section billing scope for the selected subscription-vending repository."
  default     = null
  nullable    = true
}

variable "github_repository_owner" {
  type        = string
  description = "Owner of the GitHub repositories."
}

variable "github_repository_name" {
  type        = string
  description = "Name of the GitHub repository."
}

variable "module_id" {
  type        = string
  description = "ID of the AVM (e.g. avm-ptn-alz-managment)"
}

variable "module_name" {
  type        = string
  description = "Description of the AVM (e.g. Azure Landing Zones Management Resources)"
}

variable "github_repository_pr_check_environment_name" {
  type        = string
  description = "Name of the environment used by the PR check job for OIDC, without required reviewers."
}

variable "github_repository_integration_test_environment_name" {
  type        = string
  description = "Name of the approval-gated environment used by the integration test job."
}

variable "github_repository_examples_test_environment_name" {
  type        = string
  description = "Name of the approval-gated e2e discovery environment, retained for legacy example test jobs."
}

variable "github_repository_examples_test_execution_environment_name" {
  type        = string
  description = "Name of the approval-free e2e execution environment used after protected example discovery."
  nullable    = false

  validation {
    condition = !contains([
      for name in [
        var.github_repository_pr_check_environment_name,
        var.github_repository_integration_test_environment_name,
        var.github_repository_examples_test_environment_name,
        var.github_repository_no_approval_environment_name
      ] : lower(name)
    ], lower(var.github_repository_examples_test_execution_environment_name))
    error_message = "The e2e execution environment must be distinct from every existing environment, including case-insensitive names."
  }
}

variable "github_repository_no_approval_environment_name" {
  type        = string
  description = "Name of the environment used by jobs that do not require approval."
}

variable "github_teams" {
  type = map(object({
    slug                         = string
    description                  = optional(string, "")
    repository_access_permission = optional(string, "none")
    environment_approval         = optional(bool, false)
  }))
  description = <<DESCRIPTION
Map of GitHub teams to be created or managed.

- `slug`: The slug of the team.
- `repository_access_level`: The access level for the team on the repository, can be `push` or `maintain` (default is "none").
- `environment_approval`: Whether the team is an approver for the environment (default is false)
DESCRIPTION
}

variable "labels" {
  type = map(object({
    name        = string
    color       = string
    description = string
  }))
  description = "Source csv for labels."
}

variable "is_protected_repo" {
  type        = bool
  description = "Whether the repository is protected and requires pull request approval."
}

variable "bypass_ruleset_for_approval_enabled" {
  type        = bool
  description = "Whether to bypass the ruleset for approval for the GitHub App."
}

variable "pull_request_bypass_teams" {
  type        = list(string)
  description = "GitHub team slugs allowed to bypass the main ruleset on pull requests."
}

variable "github_avm_app_id" {
  type        = string
  description = "The GitHub App ID for the AVM."
}

variable "copilot_agent_firewall_allow_list_variable_name" {
  type        = string
  description = "The name of the variable in the GitHub repository that contains the Copilot Agent firewall allow list."
}

variable "copilot_agent_firewall_allow_list" {
  type        = list(string)
  description = "List of domains to allow for GitHub Copilot Agent firewall rules."
}

variable "topics" {
  type        = list(string)
  description = <<DESCRIPTION
List of GitHub repository topics to apply to the repository. The list is set
authoritatively, so any topics not in this list will be removed from the
repository.
DESCRIPTION
  default     = []
}
