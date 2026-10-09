locals {
  identity_names = {
    for path in keys(var.modules) :
    path => "id-avm-bicep-${replace(path, "/", "-")}-${substr(sha256(path), 0, 8)}"
  }
  job_workflow_ref = "Azure/bicep-registry-modules/.github/workflows/avm.template.module.deployment.yml@refs/heads/main"
}
