data "variable" "for_attr_order" {}

locals {
  variables_for_attr_order = data.variable.for_attr_order.result
}

transform "reorder_attributes" "var_attrs" {
  for_each                 = local.variables_for_attr_order
  target_block_address     = "variable.${each.key}"
  head_attributes          = ["type", "default", "description", "nullable", "sensitive", "ephemeral"]
  sort_body_alphabetically = false
}

transform "remove_block_element" "drop_nullable_true" {
  for_each = {
    for name, variable in local.variables_for_attr_order : name => variable
    if try(variable.nullable, null) == true
  }
  target_block_address = "variable.${each.key}"
  paths                = ["nullable"]
}

transform "remove_block_element" "drop_sensitive_false" {
  for_each = {
    for name, variable in local.variables_for_attr_order : name => variable
    if try(variable.sensitive, null) == false
  }
  target_block_address = "variable.${each.key}"
  paths                = ["sensitive"]
}

transform "remove_block_element" "drop_ephemeral_false" {
  for_each = {
    for name, variable in local.variables_for_attr_order : name => variable
    if try(variable.ephemeral, null) == false
  }
  target_block_address = "variable.${each.key}"
  paths                = ["ephemeral"]
}
