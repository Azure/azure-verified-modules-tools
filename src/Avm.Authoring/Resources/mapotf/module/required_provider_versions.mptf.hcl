data "terraform" this {

}

data "resource" "for_provider_versions" {}
data "data" "for_provider_versions" {}

locals {
  azapi_provider_required = (
    can(data.terraform.this.required_providers.azapi) ||
    length([
      for t in concat(keys(data.resource.for_provider_versions.result), keys(data.data.for_provider_versions.result)) : t
      if startswith(t, "azapi_")
    ]) > 0
  )
  azapi_provider_version_valid  = try(!semvercheck(data.terraform.this.required_providers.azapi.version, "2.11.999"), false) && try(semvercheck(data.terraform.this.required_providers.azapi.version, "2.999.999"), false)
  random_provider_version_valid = try(!semvercheck(data.terraform.this.required_providers.random.version, "2.999.999"), true) && try(semvercheck(data.terraform.this.required_providers.random.version, "3.999.999"), true)
}

transform "update_in_place" azapi_provider_version {
  for_each             = local.azapi_provider_required && !local.azapi_provider_version_valid ? toset([1]) : toset([])
  target_block_address = "terraform"
  asraw {
    required_providers {
      azapi = {
        source  = "Azure/azapi"
        version = "~> 2.12"
      }
    }
  }
}

transform "update_in_place" random_provider_version {
  for_each             = !local.random_provider_version_valid ? toset([1]) : toset([])
  target_block_address = "terraform"
  asraw {
    required_providers {
      random = {
        source  = "hashicorp/random"
        version = "~> 3.0"
      }
    }
  }
  depends_on = [
    transform.update_in_place.azapi_provider_version
  ]
}