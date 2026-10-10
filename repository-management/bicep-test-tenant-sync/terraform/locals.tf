locals {
  identity_names = {
    for path in keys(var.modules) :
    path => "id-test-bicep-${replace(path, "/", "-")}"
  }
  job_workflow_ref = "Azure/bicep-registry-modules/.github/workflows/avm.template.module.deployment.yml@refs/heads/main"
}
