variable "unit_test_modtm_requirement" {
  type    = map(string)
  default = {}
}

variable "unit_test_modtm_bindings" {
  type    = map(string)
  default = {}
}

data "module" "unit_test_modtm_calls" {}

transform "update_in_place" "unit_test_modtm_requirement" {
  for_each                = length(var.unit_test_modtm_requirement) > 0 && local.provider_terraform_block_exists ? toset(["1"]) : toset([])
  target_block_address    = "terraform"
  merge_object_attributes = true
  dynamic_block_body      = "required_providers {\n  modtm = ${jsonencode(var.unit_test_modtm_requirement)}\n}\n"
}

transform "new_block" "unit_test_modtm_requirement" {
  for_each           = length(var.unit_test_modtm_requirement) > 0 && !local.provider_terraform_block_exists ? toset(["1"]) : toset([])
  new_block_type     = "terraform"
  labels             = []
  filename           = "terraform.tf"
  dynamic_block_body = "required_providers {\n  modtm = ${jsonencode(var.unit_test_modtm_requirement)}\n}\n"
}

transform "update_in_place" "unit_test_modtm_bindings" {
  for_each                = var.unit_test_modtm_bindings
  target_block_address    = "module.${each.key}"
  merge_object_attributes = true
  dynamic_block_body      = "providers = ${each.value}\n"
}
