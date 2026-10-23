locals {
  identity_names = {
    for path in keys(var.modules) :
    path => contains(keys(var.existing_identities), path) ? var.existing_identities[path].name : "id-test-bicep-${replace(path, "/", "-")}"
  }
  job_workflow_ref = "Azure/bicep-registry-modules/.github/workflows/avm.template.module.deployment.yml@refs/heads/main"
}
