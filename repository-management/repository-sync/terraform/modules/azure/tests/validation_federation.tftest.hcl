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
  target          = azapi_resource.identity[0]
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
  github_repository_environment_names = ["pr-check", "integration-test", "examples-test-execution"]
  location                            = "eastus2"
  is_protected_repo                   = true
  github_job_workflow_path            = "Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml"
  github_organization_id              = "6844498"
  github_repository_id                = "1234"
  repository_sync_repository_id       = "1239632211"
  expected_identity_context = {
    tenant_id            = "10000000-0000-4000-8000-000000000001"
    subscription_id      = "10000000-0000-4000-8000-000000000003"
    controller_client_id = "10000000-0000-4000-8000-000000000002"
  }
}

run "execution_federation_uses_the_configured_workflow_path" {
  command = plan

  assert {
    condition = (
      toset(keys({ for key, credential in azapi_resource.federated_credentials : key => credential if startswith(key, "module-") })) == toset(["module-pr-check", "module-integration-test", "module-examples-test-execution"]) &&
      alltrue([for environment in var.github_repository_environment_names :
        azapi_resource.federated_credentials["module-${trimprefix(environment, "module-")}"].type ==
        "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2025-01-31-preview" &&
        azapi_resource.federated_credentials["module-${trimprefix(environment, "module-")}"].body.properties.claimsMatchingExpression.languageVersion == 1 &&
        azapi_resource.federated_credentials["module-${trimprefix(environment, "module-")}"].body.properties.claimsMatchingExpression.value ==
        "claims['sub'] matches 'repository_owner_id:6844498:repository_id:1234:environment:${environment}:*' and claims['job_workflow_ref'] matches '${var.github_job_workflow_path}@*' and claims['repository_id'] eq '1234' and claims['repository_owner_id'] eq '6844498'" &&
        azapi_resource.federated_credentials["module-${trimprefix(environment, "module-")}"].body.properties.issuer == "https://token.actions.githubusercontent.com" &&
        tolist(azapi_resource.federated_credentials["module-${trimprefix(environment, "module-")}"].body.properties.audiences) == tolist(["api://AzureADTokenExchange"]) &&
        azapi_resource.federated_credentials["module-${trimprefix(environment, "module-")}"].name == "${local.owner_repo_name}-fic-m-${trimprefix(environment, "module-")}" &&
        azapi_resource.federated_credentials["module-${trimprefix(environment, "module-")}"].parent_id == azapi_resource.identity[0].id &&
        toset(azapi_resource.federated_credentials["module-${trimprefix(environment, "module-")}"].locks) == toset([azapi_resource.identity[0].id])
      ])
    )
    error_message = "Every execution credential must bind only the configured workflow path, repository IDs, environment, audience, issuer and dedicated identity."
  }
}

run "validation_trust_stays_on_the_same_test_identity" {
  command = plan

  assert {
    condition = (
      azapi_resource.federated_credentials["validation"].body.properties.claimsMatchingExpression.languageVersion == 1 &&
      azapi_resource.federated_credentials["validation"].body.properties.claimsMatchingExpression.value ==
      "claims['sub'] matches 'repository_owner_id:${var.github_organization_id}:repository_id:${var.repository_sync_repository_id}:environment:avm-validation' and claims['repository_id'] eq '${var.repository_sync_repository_id}' and claims['repository_owner_id'] eq '${var.github_organization_id}'" &&
      azapi_resource.federated_credentials["validation"].body.properties.issuer ==
      "https://token.actions.githubusercontent.com" &&
      length(azapi_resource.federated_credentials["validation"].body.properties.audiences) == 1 &&
      azapi_resource.federated_credentials["validation"].body.properties.audiences[0] ==
      "api://AzureADTokenExchange"
    )
    error_message = "Validation must trust only the tools repository's avm-validation environment."
  }

  assert {
    condition = (
      azapi_resource.federated_credentials["validation"].name == "${local.owner_repo_name}-fic-v-avm-validation" &&
      azapi_resource.federated_credentials["validation"].parent_id == azapi_resource.identity[0].id &&
      length(azapi_resource.federated_credentials["validation"].locks) == 1 &&
      azapi_resource.federated_credentials["validation"].locks[0] == azapi_resource.identity[0].id
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
      azapi_resource.federated_credentials["validation"].body.properties.claimsMatchingExpression.value ==
      "claims['sub'] matches 'repository_owner_id:7654321:repository_id:987654321:environment:avm-validation' and claims['repository_id'] eq '987654321' and claims['repository_owner_id'] eq '7654321'"
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

run "identity_names_preserve_the_stem_except_the_reserved_windows_substring" {
  command = plan

  variables {
    github_repository_owner = "DifferentOwner"
    github_repository_name  = "Terraform-AzAPI-Avm-Res-Compute-Windows-Terraform"
  }

  assert {
    condition = (
      azapi_resource.identity[0].name == "id-test-terraform-azapi-avm-res-compute-w5s-terraform" &&
      alltrue([for environment, credential in azapi_resource.federated_credentials :
        credential.name == "id-test-terraform-azapi-avm-res-compute-w5s-terraform-fic-m-${trimprefix(environment, "module-")}"
        if startswith(environment, "module-")
      ]) &&
      azapi_resource.federated_credentials["validation"].name == "id-test-terraform-azapi-avm-res-compute-w5s-terraform-fic-v-avm-validation"
    )
    error_message = "The owner and leading terraform- are removed, and only the reserved windows substring is abbreviated in identity and credential names."
  }
}

run "explicit_bicep_identity_names_do_not_use_the_terraform_substitution" {
  command = plan

  variables {
    identity_name          = "id-test-bicep-avm-res-compute-windows-agent"
    github_repository_name = "bicep-registry-modules"
  }

  assert {
    condition     = azapi_resource.identity[0].name == "id-test-bicep-avm-res-compute-windows-agent"
    error_message = "Explicit Bicep identity names must not change."
  }
}

run "azure_provider_remains_part_of_the_readable_identity" {
  command = plan

  variables {
    github_repository_name = "terraform-azure-avm-ptn-example-repo"
  }

  assert {
    condition     = azapi_resource.identity[0].name == "id-test-terraform-azure-avm-ptn-example-repo"
    error_message = "The azure provider component must not be confused with the omitted GitHub owner."
  }
}

run "full_identity_and_credential_names_accept_their_exact_bounds" {
  command = plan

  variables {
    github_repository_name              = "terraform-azurerm-avm-res-${join("", [for index in range(56) : "a"])}"
    github_repository_environment_names = [join("", [for index in range(23) : "a"])]
  }

  assert {
    condition = (
      length(azapi_resource.identity[0].name) == 90 &&
      alltrue([for key, credential in azapi_resource.federated_credentials : length(credential.name) == 120 if startswith(key, "module-")])
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

run "reserved_word_normalization_precedes_the_identity_length_check" {
  command = plan

  variables {
    github_repository_name = "terraform-azurerm-avm-res-windows${join("", [for index in range(53) : "a"])}"
  }

  assert {
    condition     = azapi_resource.identity[0].name == "id-test-terraform-azurerm-avm-res-w5s${join("", [for index in range(53) : "a"])}"
    error_message = "The normalized 90-character name must be accepted without truncating any other characters."
  }
}

run "overlong_credential_is_rejected_without_truncation" {
  command = plan

  variables {
    github_repository_name              = "terraform-azurerm-avm-res-${join("", [for index in range(56) : "a"])}"
    github_repository_environment_names = [join("", [for index in range(24) : "a"])]
  }

  expect_failures = [var.github_repository_environment_names]
}

run "caller_bound_credential_accepts_exactly_120_characters" {
  command = plan

  variables {
    identity_name                       = join("", [for index in range(90) : "a"])
    github_repository_name              = "bicep-registry-modules"
    github_workflow_ref                 = "Azure/bicep-registry-modules/.github/workflows/avm.res.fabric.capacity.yml@refs/heads/main"
    github_repository_environment_names = [join("", [for index in range(23) : "a"])]
  }

  assert {
    condition = (
      alltrue([for key, credential in azapi_resource.federated_credentials : length(credential.name) == 120 if startswith(key, "module-")]) &&
      alltrue([for key, credential in azapi_resource.federated_credentials :
        credential.body.properties.claimsMatchingExpression.value ==
        "claims['sub'] matches 'repository_owner_id:6844498:repository_id:1234:environment:${trimprefix(key, "module-")}:*' and claims['job_workflow_ref'] matches '${var.github_job_workflow_path}@*' and claims['sub'] matches '*:workflow_ref:Azure/bicep-registry-modules/.github/workflows/*' and claims['sub'] matches '*:workflow_ref:*/.github/workflows/avm.res.fabric.capacity.yml@refs/heads/main' and claims['repository_id'] eq '1234' and claims['repository_owner_id'] eq '6844498'"
        if startswith(key, "module-")
      ])
    )
    error_message = "The canonical fic-m- discriminator and separate bounded workflow claim comparands must be preserved."
  }
}

run "longest_published_bicep_caller_keeps_exact_bounded_claims" {
  command = plan

  variables {
    identity_name                       = "id-test-bicep-avm-res-network-application-gateway-web-application-firewall-policy"
    github_repository_name              = "bicep-registry-modules"
    github_repository_id                = "447791597"
    github_repository_environment_names = ["avm-validation"]
    github_job_workflow_path            = "Azure/bicep-registry-modules/.github/workflows/avm.template.module.deployment.yml"
    github_workflow_ref                 = "Azure/bicep-registry-modules/.github/workflows/avm.res.network.application-gateway-web-application-firewall-policy.yml@refs/heads/main"
    bicep_registry_federation_enabled   = true
  }

  assert {
    condition = (
      length(var.github_workflow_ref) == 134 &&
      length(local.caller_subject_patterns) == 2 &&
      local.caller_subject_patterns[0] == "*:workflow_ref:Azure/bicep-registry-modules/.github/workflows/*" &&
      local.caller_subject_patterns[1] == "*:workflow_ref:*/.github/workflows/avm.res.network.application-gateway-web-application-firewall-policy.yml@refs/heads/main" &&
      length(local.caller_subject_patterns[1]) == 122 &&
      azapi_resource.federated_credentials["module-avm-validation"].body.properties.claimsMatchingExpression.value ==
      "claims['sub'] matches 'repository_owner_id:6844498:repository_id:447791597:environment:avm-validation:*' and claims['job_workflow_ref'] matches '${var.github_job_workflow_path}@*' and claims['sub'] matches '${local.caller_subject_patterns[0]}' and claims['sub'] matches '${local.caller_subject_patterns[1]}' and claims['repository_id'] eq '447791597' and claims['repository_owner_id'] eq '6844498'" &&
      toset(keys(azapi_resource.federated_credentials)) == toset(["module-avm-validation", "validation", "bicep-registry"])
    )
    error_message = "Long callers must retain the complete filename, trusted main, immutable IDs and existing credential addresses within each comparand limit."
  }
}

run "caller_workflow_comparand_accepts_exactly_128_characters" {
  command = plan

  variables {
    github_workflow_ref = "Azure/terraform-azurerm-avm-ptn-example-repo/.github/workflows/${join("", [for index in range(73) : "a"])}.yml@refs/heads/main"
  }

  assert {
    condition     = length(local.caller_subject_patterns[1]) == 128
    error_message = "The complete caller filename must be accepted at the comparand boundary."
  }
}

run "overlong_caller_workflow_comparand_is_rejected" {
  command = plan

  variables {
    github_workflow_ref = "Azure/terraform-azurerm-avm-ptn-example-repo/.github/workflows/${join("", [for index in range(74) : "a"])}.yml@refs/heads/main"
  }

  expect_failures = [var.github_workflow_ref]
}

run "caller_from_another_repository_is_rejected" {
  command = plan

  variables {
    github_workflow_ref = "Azure/foreign/.github/workflows/module.yml@refs/heads/main"
  }

  expect_failures = [var.github_workflow_ref]
}

run "caller_filename_wildcard_is_rejected" {
  command = plan

  variables {
    github_workflow_ref = "Azure/terraform-azurerm-avm-ptn-example-repo/.github/workflows/*.yml@refs/heads/main"
  }

  expect_failures = [var.github_workflow_ref]
}

run "caller_non_main_ref_is_rejected" {
  command = plan

  variables {
    github_workflow_ref = "Azure/terraform-azurerm-avm-ptn-example-repo/.github/workflows/module.yml@refs/heads/feature"
  }

  expect_failures = [var.github_workflow_ref]
}

run "overlong_reusable_workflow_comparand_is_rejected" {
  command = plan

  variables {
    github_job_workflow_path = "Azure/${join("", [for index in range(100) : "a"])}/.github/workflows/module.yml"
  }

  expect_failures = [var.github_job_workflow_path]
}

run "overlong_caller_bound_credential_is_rejected" {
  command = plan

  variables {
    identity_name                       = join("", [for index in range(90) : "a"])
    github_repository_name              = "bicep-registry-modules"
    github_workflow_ref                 = "Azure/bicep-registry-modules/.github/workflows/avm.res.fabric.capacity.yml@refs/heads/main"
    github_repository_environment_names = [join("", [for index in range(24) : "a"])]
  }

  expect_failures = [var.github_repository_environment_names]
}
