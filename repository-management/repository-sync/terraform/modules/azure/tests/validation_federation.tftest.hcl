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
  target = data.azuread_client_config.current
  values = {
    tenant_id = "10000000-0000-4000-8000-000000000001"
    client_id = "10000000-0000-4000-8000-000000000002"
    object_id = "10000000-0000-4000-8000-000000000011"
  }
}

override_resource {
  target          = azapi_resource.identity
  override_during = plan
  values = {
    id = "/subscriptions/10000000-0000-4000-8000-000000000003/resourceGroups/rg-bami-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-test-terraform-azurerm-avm-ptn-example-repo"
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
  expected_identity_context = {
    tenant_id            = "10000000-0000-4000-8000-000000000001"
    subscription_id      = "10000000-0000-4000-8000-000000000003"
    controller_client_id = "10000000-0000-4000-8000-000000000002"
  }
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

run "identity_names_preserve_provider_and_complete_stem_without_owner_or_hash" {
  command = plan

  variables {
    github_repository_owner = "DifferentOwner"
    github_repository_name  = "Terraform-AzAPI-Avm-Res-Compute-Windows-Terraform"
  }

  assert {
    condition     = azapi_resource.identity.name == "id-test-terraform-azapi-avm-res-compute-windows-terraform"
    error_message = "Only the owner and leading terraform- must be removed; the full lowercase stem must be preserved."
  }
}

run "azure_provider_remains_part_of_the_readable_identity" {
  command = plan

  variables {
    github_repository_name = "terraform-azure-avm-ptn-example-repo"
  }

  assert {
    condition     = azapi_resource.identity.name == "id-test-terraform-azure-avm-ptn-example-repo"
    error_message = "The azure provider component must not be confused with the omitted GitHub owner."
  }
}

run "full_identity_and_credential_names_accept_their_exact_bounds" {
  command = plan

  variables {
    github_repository_name              = "terraform-azurerm-avm-res-${join("", [for index in range(56) : "a"])}"
    github_repository_environment_names = [join("", [for index in range(29) : "a"])]
  }

  assert {
    condition = (
      length(azapi_resource.identity.name) == 90 &&
      alltrue([for credential in azapi_resource.identity_federated_credentials : length(credential.name) == 120])
    )
    error_message = "Complete identity and federation names must retain every character at their respective bounds."
  }
}

run "overlong_identity_is_rejected_without_truncation" {
  command = plan

  variables {
    github_repository_name = "terraform-azurerm-avm-res-${join("", [for index in range(57) : "a"])}"
  }

  expect_failures = [var.github_repository_name]
}

run "overlong_credential_is_rejected_without_truncation" {
  command = plan

  variables {
    github_repository_name              = "terraform-azurerm-avm-res-${join("", [for index in range(56) : "a"])}"
    github_repository_environment_names = [join("", [for index in range(30) : "a"])]
  }

  expect_failures = [var.github_repository_environment_names]
}

run "caller_bound_credential_accepts_exactly_120_characters" {
  command = plan

  variables {
    identity_name                       = join("", [for index in range(90) : "a"])
    github_workflow_ref                 = "Azure/bicep-registry-modules/.github/workflows/avm.res.fabric.capacity.yml@refs/heads/main"
    github_repository_environment_names = [join("", [for index in range(22) : "a"])]
  }

  assert {
    condition     = alltrue([for credential in azapi_resource.identity_federated_credentials : length(credential.name) == 120])
    error_message = "The module- discriminator must be counted in caller-bound credential names."
  }
}

run "overlong_caller_bound_credential_is_rejected" {
  command = plan

  variables {
    identity_name                       = join("", [for index in range(90) : "a"])
    github_workflow_ref                 = "Azure/bicep-registry-modules/.github/workflows/avm.res.fabric.capacity.yml@refs/heads/main"
    github_repository_environment_names = [join("", [for index in range(23) : "a"])]
  }

  expect_failures = [var.github_repository_environment_names]
}
