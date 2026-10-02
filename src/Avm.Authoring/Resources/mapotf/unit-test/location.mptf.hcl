variable "new_location_modules" {
  type    = set(string)
  default = []
}

data "test_file" "this" {}

locals {
  test_file = data.test_file.this.result
  global_location_authored = contains(
    keys(try(local.test_file.variables.mptf.attributes, {})),
    "location"
  )
  local_runs = {
    for name, target in local.test_file.run_modules : name => target
    if contains(["root", "local"], target.kind)
  }
  new_location_runs = {
    for name, target in local.local_runs : name => local.test_file.runs[name]
    if (
      contains(var.new_location_modules, target.dir) &&
      !local.global_location_authored &&
      !contains(keys(try(local.test_file.runs[name].variables[0].mptf.attributes, {})), "location")
    )
  }
}

transform "update_in_place" "new_location" {
  for_each             = local.new_location_runs
  target_block_address = each.value.mptf.block_address
  asraw {
    variables {
      location = "eastus"
    }
  }
}
