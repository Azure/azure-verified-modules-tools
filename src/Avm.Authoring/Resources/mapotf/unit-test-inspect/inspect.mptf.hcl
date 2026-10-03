variable "allowed_module_directories" {
  type    = set(string)
  default = []
}

data "test_file" "this" {}

locals {
  local_runs = {
    for name, target in data.test_file.this.result.run_modules : name => target
    if contains(["root", "local"], target.kind)
  }
  local_target_directories = toset([
    for target in values(local.local_runs) : target.dir
    if contains(var.allowed_module_directories, target.dir)
  ])
}

data "module_source" "targets" {
  for_each = local.local_target_directories
  source   = each.value
}
