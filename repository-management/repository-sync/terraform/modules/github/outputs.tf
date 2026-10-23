output "organization_id" {
  description = "The GitHub organization ID."
  value       = data.github_organization.this.id
}

output "repository_id" {
  description = "The GitHub repository ID."
  value       = github_repository.this.repo_id
}

output "subscription_vending_contract" {
  description = "Names of the targeted subscription-vending repository settings, without exposing their values."
  value = {
    billing_scope_secret_name      = var.subscription_vending_billing_scope == null ? null : "TF_VAR_subscription_billing_scope"
    management_group_secret_name   = var.subscription_vending_management_group_id == null ? null : "TF_VAR_subscription_management_group_id"
    management_group_variable_name = var.subscription_vending_management_group_id == null ? null : "TEST_BAMI_SUBSCRIPTION_VENDING_MANAGEMENT_GROUP_ID"
  }
}