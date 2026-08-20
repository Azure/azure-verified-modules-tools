data "terraform" "for_order" {}

locals {
  ordered_required_providers = {
    for provider_name in sort(keys(data.terraform.for_order.required_providers)) :
    provider_name => data.terraform.for_order.required_providers[provider_name]
  }
}

transform "update_in_place" "required_providers" {
  target_block_address = "terraform"
  dynamic_block_body   = <<-HCL
    required_providers = ${jsonencode(local.ordered_required_providers)}
  HCL
}

transform "reorder_attributes" "block_layout" {
  target_block_address     = "terraform"
  head_attributes          = ["required_version"]
  body_attributes          = ["experiments", "backend", "cloud", "provider_meta"]
  foot_attributes          = ["required_providers"]
  sort_body_alphabetically = true
}
