locals {
  identity_names = {
    for path in keys(var.modules) :
    path => contains(keys(var.existing_identities), path) ? var.existing_identities[path].name : "id-test-bicep-${replace(path, "/", "-")}"
  }
}
