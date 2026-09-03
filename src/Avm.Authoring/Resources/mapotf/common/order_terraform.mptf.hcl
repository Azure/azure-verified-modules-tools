data "terraform" "for_order" {}

locals {
  required_providers_exists = try(data.terraform.for_order.block.required_providers != null, false)
}

transform "reorder_attributes" "block_layout" {
  target_block_address     = "terraform"
  head_attributes          = ["required_version"]
  body_attributes          = ["experiments", "backend", "cloud", "provider_meta"]
  foot_attributes          = ["required_providers"]
  sort_body_alphabetically = true
}

transform "reorder_attributes" "required_providers_entries" {
  for_each             = local.required_providers_exists ? toset([1]) : toset([])
  target_block_address = "terraform"
  nested_block_path    = ["required_providers"]
}
