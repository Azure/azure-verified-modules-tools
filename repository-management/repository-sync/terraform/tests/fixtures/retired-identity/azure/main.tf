terraform {
  required_providers {
    azapi = {
      source = "Azure/azapi"
    }
    azuread = {
      source = "hashicorp/azuread"
    }
  }
}

data "azapi_client_config" "current" {}

data "azuread_group" "entra_readers" {
  display_name = "retired-reader-fixture"
}

resource "azapi_resource" "identity" {
  type      = "Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview"
  parent_id = "/subscriptions/${data.azapi_client_config.current.subscription_id}/resourceGroups/retired-fixture"
  name      = "retired-fixture"
  location  = "eastus2"
  body      = {}
}

resource "azapi_resource" "identity_role_assignment" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  parent_id = "/providers/Microsoft.Management/managementGroups/retired-fixture"
  name      = "20000000-0000-4000-8000-000000000008"
  body = {
    properties = {
      principalId      = azapi_resource.identity.output.properties.principalId
      principalType    = "ServicePrincipal"
      roleDefinitionId = "/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
    }
  }
}

resource "azapi_resource" "identity_federated_credentials" {
  for_each = toset(["pr-check", "integration-test", "examples-test", "avm-validation"])

  type      = "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-07-31-preview"
  parent_id = azapi_resource.identity.id
  name      = each.value
  body = {
    properties = {
      audiences = ["api://AzureADTokenExchange"]
      issuer    = "https://token.actions.githubusercontent.com"
      subject   = "retired-fixture:${each.value}"
    }
  }
}

resource "azuread_group_member" "example" {
  group_object_id  = data.azuread_group.entra_readers.object_id
  member_object_id = azapi_resource.identity.output.properties.principalId
}
