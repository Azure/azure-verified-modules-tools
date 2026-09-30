mock_provider "azapi" {}
mock_provider "azuread" {}

override_data {
  target = data.azapi_client_config.current
  values = {
    tenant_id       = "10000000-0000-4000-8000-000000000001"
    subscription_id = "10000000-0000-4000-8000-000000000003"
  }
}

override_data {
  target = data.azuread_group.entra_readers
  values = {
    object_id = "10000000-0000-4000-8000-000000000007"
  }
}

override_resource {
  target          = azapi_resource.identity
  override_during = plan
  values = {
    id = "/subscriptions/10000000-0000-4000-8000-000000000003/resourceGroups/rg-bami-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/Azure-terraform-azurerm-avm-ptn-example-repo"
    output = {
      properties = {
        principalId = "10000000-0000-4000-8000-000000000008"
        clientId    = "10000000-0000-4000-8000-000000000006"
        tenantId    = "10000000-0000-4000-8000-000000000001"
      }
    }
  }
}

variables {
  management_group_id                 = "mg-bami-test"
  identity_resource_group_name        = "rg-bami-test"
  github_repository_owner             = "Azure"
  github_repository_name              = "terraform-azurerm-avm-ptn-example-repo"
  github_repository_environment_names = ["pr-check", "integration-test", "examples-test"]
  location                            = "eastus2"
  is_protected_repo                   = true
  github_job_workflow_ref             = "Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@refs/heads/main"
  github_organization_id              = "6844498"
  github_repository_id                = "1234"
  repository_sync_repository_id       = "1239632211"
}

run "existing_environments_keep_their_module_trust" {
  command = plan

  assert {
    condition = (
      length(azapi_resource.identity_federated_credentials) == 3 &&
      alltrue([for environment in var.github_repository_environment_names :
        azapi_resource.identity_federated_credentials[environment].body.properties.subject ==
        "repository_owner_id:6844498:repository_id:1234:environment:${environment}:job_workflow_ref:${var.github_job_workflow_ref}"
      ])
    )
    error_message = "All three module environments must retain their existing reusable-workflow trust."
  }
}

run "validation_trust_stays_on_the_same_test_identity" {
  command = plan

  assert {
    condition = (
      azapi_resource.validation_federated_credential.body.properties.subject ==
      "repository_owner_id:${var.github_organization_id}:repository_id:${var.repository_sync_repository_id}:environment:avm-validation" &&
      azapi_resource.validation_federated_credential.body.properties.issuer ==
      "https://token.actions.githubusercontent.com" &&
      length(azapi_resource.validation_federated_credential.body.properties.audiences) == 1 &&
      azapi_resource.validation_federated_credential.body.properties.audiences[0] ==
      "api://AzureADTokenExchange"
    )
    error_message = "Validation must trust only the tools repository's avm-validation environment."
  }

  assert {
    condition = (
      azapi_resource.validation_federated_credential.name == "${local.owner_repo_name}-avm-validation" &&
      azapi_resource.validation_federated_credential.parent_id == azapi_resource.identity.id &&
      length(azapi_resource.validation_federated_credential.locks) == 1 &&
      azapi_resource.validation_federated_credential.locks[0] == azapi_resource.identity.id
    )
    error_message = "Validation federation must remain on the existing module test identity."
  }
}

run "validation_subject_follows_the_verified_context_inputs" {
  command = plan

  variables {
    github_organization_id        = "7654321"
    repository_sync_repository_id = "987654321"
  }
  assert {
    condition = (
      azapi_resource.validation_federated_credential.body.properties.subject ==
      "repository_owner_id:7654321:repository_id:987654321:environment:avm-validation"
    )
    error_message = "Validation subject must be built from the supplied organization and tools repository IDs."
  }
}

run "validation_rejects_absent_repository_id" {
  command = plan

  variables {
    repository_sync_repository_id = null
  }
  expect_failures = [var.repository_sync_repository_id]
}

run "validation_rejects_nonpositive_repository_ids" {
  command = plan

  variables {
    repository_sync_repository_id = "0"
  }
  expect_failures = [var.repository_sync_repository_id]
}

run "validation_rejects_nonnumeric_repository_ids" {
  command = plan

  variables {
    repository_sync_repository_id = "123abc"
  }
  expect_failures = [var.repository_sync_repository_id]
}
