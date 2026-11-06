locals {
  repository_name          = lower(var.github_repository_name)
  owner_repo_name          = var.identity_name == null ? "id-test-terraform-${replace(trimprefix(local.repository_name, "terraform-"), "windows", "w5s")}" : var.identity_name
  dedicated_identity       = var.existing_identity == null
  identity_name            = local.dedicated_identity ? local.owner_repo_name : var.existing_identity.name
  identity_resource_id     = local.dedicated_identity ? azapi_resource.identity[0].id : data.azapi_resource.existing_identity[0].id
  identity_properties      = local.dedicated_identity ? azapi_resource.identity[0].output.properties : data.azapi_resource.existing_identity[0].output.properties
  federation_identity_name = local.dedicated_identity ? local.identity_name : "${local.identity_name}-${var.existing_identity.federation_name_key}"
  caller_subject_patterns = var.github_workflow_ref == null ? [] : [
    "*:workflow_ref:${split("/.github/workflows/", var.github_workflow_ref)[0]}/.github/workflows/*",
    "*:workflow_ref:*/.github/workflows/${try(split("/.github/workflows/", var.github_workflow_ref)[1], "")}",
  ]
  module_subject_patterns = {
    for environment in var.github_repository_environment_names :
    environment => "repository_owner_id:${var.github_organization_id}:repository_id:${var.github_repository_id}:environment:${environment}:*"
  }
  module_federated_credentials = {
    for environment, subject_pattern in local.module_subject_patterns :
    "module-${environment}" => {
      name                    = "${local.federation_identity_name}-fic-m-${environment}"
      subject_pattern         = subject_pattern
      job_workflow_pattern    = "${var.github_job_workflow_path}@*"
      caller_subject_patterns = local.caller_subject_patterns
      repository_id           = var.github_repository_id
    }
  }
  validation_federated_credentials = var.existing_identity == null || var.existing_identity.manage_entra_groups ? {
    validation = {
      name            = "${local.federation_identity_name}-fic-v-avm-validation"
      subject_pattern = "repository_owner_id:${var.github_organization_id}:repository_id:${var.repository_sync_repository_id}:environment:avm-validation"
      repository_id   = var.repository_sync_repository_id
    }
  } : {}
  registry_federated_credentials = var.bicep_registry_federation_enabled ? {
    bicep-registry = {
      name            = "${local.federation_identity_name}-fic-r-avm-validation"
      subject_pattern = "repository_owner_id:${var.github_organization_id}:repository_id:${var.github_repository_id}:environment:avm-validation"
      repository_id   = var.github_repository_id
    }
  } : {}
  federated_credentials = merge(
    local.module_federated_credentials,
    local.validation_federated_credentials,
    local.registry_federated_credentials,
  )
  federated_credential_claim_clauses = {
    for key, credential in local.federated_credentials :
    key => concat(
      ["claims['sub'] matches '${credential.subject_pattern}'"],
      try(credential.job_workflow_pattern, null) == null ? [] : ["claims['job_workflow_ref'] matches '${credential.job_workflow_pattern}'"],
      [for pattern in try(credential.caller_subject_patterns, []) : "claims['sub'] matches '${pattern}'"],
      [
        "claims['repository_id'] eq '${credential.repository_id}'",
        "claims['repository_owner_id'] eq '${var.github_organization_id}'",
      ],
    )
  }
  member_is_repository_identity = (
    lower(local.identity_properties.tenantId) == lower(data.azapi_client_config.current.tenant_id) &&
    lower(local.identity_properties.clientId) != lower(data.azuread_client_config.current.client_id) &&
    lower(local.identity_properties.principalId) != lower(data.azuread_client_config.current.object_id) &&
    (var.expected_identity_context.bicep_client_id == null ? true :
      lower(local.identity_properties.clientId) != lower(var.expected_identity_context.bicep_client_id)
    )
  )
}