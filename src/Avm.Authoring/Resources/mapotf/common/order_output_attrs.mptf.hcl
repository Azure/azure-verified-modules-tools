data "output" "for_attr_order" {}

locals {
  outputs_for_attr_order = data.output.for_attr_order.result
}

transform "reorder_attributes" "output_attrs" {
  for_each                 = local.outputs_for_attr_order
  target_block_address     = "output.${each.key}"
  sort_body_alphabetically = true
}

transform "remove_block_element" "drop_output_sensitive_false" {
  for_each = {
    for name, output in local.outputs_for_attr_order : name => output
    if try(output.sensitive, null) == false
  }
  target_block_address = "output.${each.key}"
  paths                = ["sensitive"]
}

transform "remove_block_element" "drop_output_ephemeral_false" {
  for_each = {
    for name, output in local.outputs_for_attr_order : name => output
    if try(output.ephemeral, null) == false
  }
  target_block_address = "output.${each.key}"
  paths                = ["ephemeral"]
}
