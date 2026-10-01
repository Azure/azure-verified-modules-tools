data "azapi_client_config" "current" {
  lifecycle {
    postcondition {
      condition     = var.bami_group_settings == null ? true : lower(self.tenant_id) == lower(var.bami_group_settings.tenant_id)
      error_message = "The Azure provider must use the pinned BAMI tenant."
    }
  }
}

data "azuread_client_config" "bami" {
  count = var.bami_group_settings == null ? 0 : 1

  lifecycle {
    postcondition {
      condition = (
        lower(self.tenant_id) == lower(var.bami_group_settings.tenant_id) &&
        lower(self.client_id) == lower(var.bami_group_settings.controller_client_id)
      )
      error_message = "The Graph provider must use the pinned BAMI tenant and controller."
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

# Add owner role assignment.
# The condition prevents the assignee from creating new role assignments for owner, user access administrator, or role based access control administrator.
resource "azapi_resource" "identity_role_assignment" {
  count     = var.bami_group_settings == null ? 1 : 0
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "${var.github_repository_owner}${var.github_repository_name}${var.management_group_id}${data.azapi_client_config.current.tenant_id}")
  parent_id = "/providers/Microsoft.Management/managementGroups/${var.management_group_id}"
  body = {
    properties = {
      roleDefinitionId = "/providers/Microsoft.Authorization/roleDefinitions/${local.role_definition_name_owner}"
      principalType    = "ServicePrincipal"
      principalId      = azapi_resource.identity.output.properties.principalId
      description      = "Role assignment for AVM testing. Repo: ${var.github_repository_owner}/${var.github_repository_name}"
      conditionVersion = "2.0"
      condition        = <<CONDITION
(
 (
  !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
 )
 OR
 (
  @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {${local.role_definition_name_owner}, 18d7d88d-d35e-4fb5-a5c3-7773c20a72d9, f58310d9-a9f6-439a-9e8d-f62e7b41a168}
 )
)
AND
(
 (
  !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
 )
 OR
 (
  @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {${local.role_definition_name_owner}, 18d7d88d-d35e-4fb5-a5c3-7773c20a72d9, f58310d9-a9f6-439a-9e8d-f62e7b41a168}
 )
)
CONDITION
    }
  }
}

data "azuread_group" "entra_readers" {
  display_name = var.bami_group_settings == null ? local.entra_readers_group_name : null
  object_id    = var.bami_group_settings == null ? null : var.bami_group_settings.entra_readers_group_id

  lifecycle {
    postcondition {
      condition = var.bami_group_settings == null ? true : (
        lower(self.object_id) == lower(var.bami_group_settings.entra_readers_group_id) &&
        self.display_name == "avm-test-entra-readers" &&
        self.security_enabled && !self.mail_enabled &&
        length(self.types) == 0 && self.onpremises_sync_enabled != true
      )
      error_message = "BAMI readers must resolve by pinned object ID to the assigned avm-test-entra-readers security group."
    }
  }
}

data "azuread_group" "test_permissions" {
  for_each = local.bami_group_contracts

  object_id = each.value.object_id

  lifecycle {
    postcondition {
      condition = (
        lower(self.object_id) == lower(each.value.object_id) &&
        self.display_name == each.value.display_name &&
        self.security_enabled && !self.mail_enabled &&
        length(self.types) == 0 && self.onpremises_sync_enabled != true
      )
      error_message = "BAMI access groups must match their pinned object IDs, names, and assigned security-group contract."
    }
  }
}

resource "azuread_group_member" "example" {
  group_object_id  = data.azuread_group.entra_readers.object_id
  member_object_id = azapi_resource.identity.output.properties.principalId

  lifecycle {
    precondition {
      condition     = local.bami_member_is_repository_identity
      error_message = "Only the dedicated BAMI repository identity, never the controller, may receive test group membership."
    }
  }
}

resource "azuread_group_member" "test_identity_owners" {
  count = var.bami_group_settings == null ? 0 : 1

  group_object_id  = data.azuread_group.test_permissions["test_identity_owners"].object_id
  member_object_id = azapi_resource.identity.output.properties.principalId

  lifecycle {
    precondition {
      condition     = local.bami_member_is_repository_identity
      error_message = "Only the dedicated BAMI repository identity, never the controller, may receive test Owner membership."
    }
  }
}

resource "azuread_group_member" "fabric_admins" {
  count = var.bami_group_settings == null ? 0 : (var.bami_group_settings.fabric_admin_apis ? 1 : 0)

  group_object_id  = data.azuread_group.test_permissions["fabric_admins"].object_id
  member_object_id = azapi_resource.identity.output.properties.principalId

  lifecycle {
    precondition {
      condition     = local.bami_member_is_repository_identity
      error_message = "Only an explicitly opted-in dedicated BAMI repository identity may receive Fabric admin API membership."
    }
  }
}

moved {
  from = azapi_resource.identity_role_assignment
  to   = azapi_resource.identity_role_assignment[0]
}
