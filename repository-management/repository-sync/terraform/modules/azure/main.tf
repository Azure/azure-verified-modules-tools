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
  count     = var.existing_identity == null ? 1 : 0
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

data "azapi_resource" "existing_identity" {
  count = var.existing_identity == null ? 0 : 1

  type = "Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview"
  parent_id = trimsuffix(
    var.existing_identity.resource_id,
    "/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${var.existing_identity.name}"
  )
  name = var.existing_identity.name
  response_export_values = [
    "properties.principalId",
    "properties.clientId",
    "properties.tenantId"
  ]

  lifecycle {
    precondition {
      condition = (
        can(regex("^/subscriptions/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/resourceGroups/[A-Za-z0-9_().-]{1,90}/providers/Microsoft\\.ManagedIdentity/userAssignedIdentities/[A-Za-z0-9][A-Za-z0-9_-]{2,89}$", var.existing_identity.resource_id)) &&
        alltrue([
          for id in [var.existing_identity.client_id, var.existing_identity.principal_id] :
          can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id)) &&
          lower(id) != "00000000-0000-0000-0000-000000000000"
        ]) &&
        can(regex("^[a-z][a-z0-9-]{2,31}$", var.existing_identity.federation_name_key)) &&
        length("${var.existing_identity.name}-${var.existing_identity.federation_name_key}-registry-avm-validation") <= 120
      )
      error_message = "Existing identity evidence must bind a valid UAMI, nonempty client/principal GUIDs, and federation names no longer than 120 characters."
    }

    postcondition {
      condition = (
        self.id == var.existing_identity.resource_id &&
        lower(self.output.properties.tenantId) == lower(data.azapi_client_config.current.tenant_id) &&
        lower(self.output.properties.clientId) == lower(var.existing_identity.client_id) &&
        lower(self.output.properties.principalId) == lower(var.existing_identity.principal_id)
      )
      error_message = "Bootstrap identity evidence must resolve to the configured BAMI tenant, resource, client, and principal."
    }
  }
}

resource "azapi_resource" "identity_federated_credentials" {
  for_each = var.github_repository_environment_names

  type      = "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-07-31-preview"
  name      = var.github_workflow_ref == null ? "${local.federation_identity_name}-${each.value}" : "${local.federation_identity_name}-module-${each.value}"
  parent_id = local.identity_resource_id
  locks     = [local.identity_resource_id]
  body = {
    properties = {
      audiences = ["api://AzureADTokenExchange"]
      issuer    = "https://token.actions.githubusercontent.com"
      # OIDC subject layout matches the `include_claim_keys` order configured in
      # modules/github/github.actions_oidc.tf. The `context` claim is not
      # included literally in `sub`; it expands to its value, which is
      # `environment:<name>` when the job references an environment.
      subject = join("", [
        "repository_owner_id:${var.github_organization_id}:repository_id:${var.github_repository_id}:environment:${each.value}:job_workflow_ref:${var.github_job_workflow_ref}",
        var.github_workflow_ref == null ? "" : ":workflow_ref:${var.github_workflow_ref}"
      ])
    }
  }
}

resource "azapi_resource" "validation_federated_credential" {
  type      = "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-07-31-preview"
  name      = "${local.federation_identity_name}-avm-validation"
  parent_id = local.identity_resource_id
  locks     = [local.identity_resource_id]
  body = {
    properties = {
      audiences = ["api://AzureADTokenExchange"]
      issuer    = "https://token.actions.githubusercontent.com"
      subject   = "repository_owner_id:${var.github_organization_id}:repository_id:${var.repository_sync_repository_id}:environment:avm-validation"
    }
  }
}

resource "azapi_resource" "bicep_registry_federated_credential" {
  count = var.bicep_registry_federation_enabled ? 1 : 0

  type      = "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-07-31-preview"
  name      = "${local.federation_identity_name}-registry-avm-validation"
  parent_id = local.identity_resource_id
  locks     = [local.identity_resource_id]
  body = {
    properties = {
      audiences = ["api://AzureADTokenExchange"]
      issuer    = "https://token.actions.githubusercontent.com"
      subject   = "repository_owner_id:${var.github_organization_id}:repository_id:${var.github_repository_id}:environment:avm-validation"
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
        self.security_enabled &&
        !contains(self.types, "DynamicMembership") &&
        (
          var.existing_identity == null ||
          var.existing_identity.manage_entra_groups ||
          contains(self.members, var.existing_identity.principal_id)
        )
      )
      error_message = "Configured Entra names must resolve to security groups that permit individual membership management and, when Bicep owns external membership, already contain the bootstrap principal."
    }
  }
}

resource "azuread_group_member" "test_permissions" {
  for_each = var.existing_identity == null || var.existing_identity.manage_entra_groups ? var.entra_group_names : []

  group_object_id  = data.azuread_group.test_permissions[each.key].object_id
  member_object_id = local.identity_properties.principalId

  lifecycle {
    precondition {
      condition     = local.member_is_repository_identity
      error_message = "Only the dedicated repository test identity, never the controller, may receive configured group memberships."
    }
  }
}

moved {
  from = azapi_resource.identity
  to   = azapi_resource.identity[0]
}
