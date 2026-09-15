variable "repository_creation_mode_enabled" {
  type        = bool
  description = "Whether we are running in repository creation mode."
  default     = false
}

variable "bami_test_settings" {
  type = object({
    tenant_id            = string
    client_id            = string
    controller_client_id = string
    bicep_client_id      = string
    test_subscription_ids = list(object({
      name = string
      id   = string
    }))
  })
  description = "Complete verified candidate test settings; null retains the legacy identity and subscriptions."
  default     = null

  validation {
    condition = var.bami_test_settings == null ? true : (
      alltrue([
        for id in [
          var.bami_test_settings.tenant_id, var.bami_test_settings.client_id,
          var.bami_test_settings.controller_client_id, var.bami_test_settings.bicep_client_id
        ] : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id)) && lower(id) != "00000000-0000-0000-0000-000000000000"
      ]) &&
      lower(var.bami_test_settings.client_id) != lower(var.bami_test_settings.controller_client_id) &&
      lower(var.bami_test_settings.client_id) != lower(var.bami_test_settings.bicep_client_id) &&
      lower(var.bami_test_settings.controller_client_id) != lower(var.bami_test_settings.bicep_client_id) &&
      length(var.bami_test_settings.test_subscription_ids) == 28 &&
      length(distinct([for subscription in var.bami_test_settings.test_subscription_ids : lower(subscription.id)])) == 28 &&
      length(distinct([for subscription in var.bami_test_settings.test_subscription_ids : lower(subscription.name)])) == 28 &&
      alltrue([
        for subscription in var.bami_test_settings.test_subscription_ids :
        trimspace(subscription.name) != "" &&
        can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", subscription.id)) &&
        lower(subscription.id) != "00000000-0000-0000-0000-000000000000"
      ])
    )
    error_message = "BAMI requires complete GUID settings, 28 unique subscriptions, and separate repository, controller, and Bicep client IDs."
  }
}

variable "management_group_id" {
  type        = string
  description = "Id of the management group to create the role assignment in."
}

variable "test_subscription_ids" {
  type = list(object({
    name = string
    id   = string
  }))
  description = "List of subscription IDs to use for testing."
}

variable "identity_resource_group_name" {
  type        = string
  description = "Name of the resource group to create the identities in."
}

variable "github_repository_owner" {
  type        = string
  description = "Owner of the GitHub repositories."
  default     = "Azure"
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
  description = "Name of the approval-gated environment used by the PR check job."
  default     = "pr-check"
}

variable "github_repository_integration_test_environment_name" {
  type        = string
  description = "Name of the approval-gated environment used by the integration test job."
  default     = "integration-test"
}

variable "github_repository_examples_test_environment_name" {
  type        = string
  description = "Name of the approval-gated environment used by the example test jobs."
  default     = "examples-test"
}

variable "github_repository_no_approval_environment_name" {
  type        = string
  description = "Name of the environment used by jobs that do not require approval (still required to satisfy the OIDC subject claim)."
  default     = "no-approval"
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

variable "location" {
  type        = string
  description = "Location of the resources."
  default     = "eastus2"
}

variable "github_labels_source_path" {
  type        = string
  description = "Source csv for labels."
  default     = "../temp/labels.csv"
}

variable "is_protected_repo" {
  type        = bool
  description = "Whether the repository is protected and requires pull request approval."
  default     = true
}

variable "github_job_workflow_ref" {
  type        = string
  description = "GitHub job workflow ref to use for the federated identity credentials."
  default     = "Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@refs/heads/main"
}

variable "github_avm_app_id" {
  type        = string
  description = "The GitHub App ID for the AVM."
  default     = "1049636"
}

variable "github_copilot_agent_firewall_allow_list_variable_name" {
  type        = string
  description = "The name of the variable in the GitHub repository that contains the Copilot Agent firewall allow list."
  default     = "COPILOT_AGENT_FIREWALL_ALLOW_LIST_ADDITIONS"
}

variable "github_copilot_agent_firewall_allow_list" {
  type        = list(string)
  description = "List of domains to allow for GitHub Copilot Agent firewall rules."
  default = [
    "hashicorp.com",
    "registry.opentofu.org",
    "registry.terraform.io",
  ]
}

variable "topics" {
  type        = list(string)
  description = <<DESCRIPTION
List of GitHub repository topics to apply to the repository. The list is set
authoritatively, so any topics not in this list will be removed from the
repository. The caller is expected to merge the global default topics with
any tier-specific topics before passing them in.
DESCRIPTION
  default     = []
}
