data "azapi_client_config" "current" {
  lifecycle {
    postcondition {
      condition = (
        lower(self.tenant_id) == lower(var.expected_identity_context.tenant_id) &&
        lower(self.subscription_id) == lower(var.expected_identity_context.subscription_id)
      )
      error_message = "The Azure provider must use the selected test identity tenant and subscription."
    }
  }
}

data "azuread_client_config" "current" {
  lifecycle {
    postcondition {
      condition = (
        lower(self.tenant_id) == lower(data.azapi_client_config.current.tenant_id) &&
        lower(self.client_id) == lower(var.expected_identity_context.controller_client_id)
      )
      error_message = "The Graph provider must match the identity's tenant and selected controller."
    }
  }
}

resource "azapi_resource" "identity" {
  type      = "Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview"
  parent_id = "/subscriptions/${data.azapi_client_config.current.subscription_id}/resourceGroups/${var.identity_resource_group_name}"
  name      = local.owner_repo_name
  location  = var.location
  body      = {} # empty body as HCL object is reqired to force output to be HCL and not JSON string.
  response_export_values = [
    "properties.principalId",
    "properties.clientId",
    "properties.tenantId"
  ]
}

resource "azapi_resource" "identity_federated_credentials" {
  for_each = var.github_repository_environment_names

  type      = "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-07-31-preview"
  name      = "${local.owner_repo_name}-${each.value}"
  parent_id = azapi_resource.identity.id
  locks     = [azapi_resource.identity.id]
  body = {
    properties = {
      audiences = ["api://AzureADTokenExchange"]
      issuer    = "https://token.actions.githubusercontent.com"
      # OIDC subject layout matches the `include_claim_keys` order configured in
      # modules/github/github.actions_oidc.tf. The `context` claim is not
      # included literally in `sub`; it expands to its value, which is
      # `environment:<name>` when the job references an environment.
      subject = "repository_owner_id:${var.github_organization_id}:repository_id:${var.github_repository_id}:environment:${each.value}:job_workflow_ref:${var.github_job_workflow_ref}"
    }
  }
}

resource "azapi_resource" "validation_federated_credential" {
  type      = "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-07-31-preview"
  name      = "${local.owner_repo_name}-avm-validation"
  parent_id = azapi_resource.identity.id
  locks     = [azapi_resource.identity.id]
  body = {
    properties = {
      audiences = ["api://AzureADTokenExchange"]
      issuer    = "https://token.actions.githubusercontent.com"
      subject   = "repository_owner_id:${var.github_organization_id}:repository_id:${var.repository_sync_repository_id}:environment:avm-validation"
    }
  }
}

data "azuread_group" "test_permissions" {
  for_each = var.entra_group_names

  display_name     = each.value
  security_enabled = true

  lifecycle {
    postcondition {
      condition = (
        self.display_name == each.value &&
        self.security_enabled && !contains(self.types, "DynamicMembership")
      )
      error_message = "Configured Entra names must resolve uniquely to security groups that permit individual membership management."
    }
  }
}

resource "azuread_group_member" "test_permissions" {
  for_each = var.entra_group_names

  group_object_id  = data.azuread_group.test_permissions[each.key].object_id
  member_object_id = azapi_resource.identity.output.properties.principalId

  lifecycle {
    precondition {
      condition     = local.member_is_repository_identity
      error_message = "Only the dedicated repository test identity, never the controller, may receive configured group memberships."
    }
  }
}
