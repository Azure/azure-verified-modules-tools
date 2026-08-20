transform "reorder_attributes" "block_layout" {
  target_block_address     = "terraform"
  head_attributes          = ["required_version"]
  body_attributes          = ["experiments", "backend", "cloud", "provider_meta"]
  foot_attributes          = ["required_providers"]
  sort_body_alphabetically = true
}

transform "reorder_attributes" "required_providers_entries" {
  target_block_address = "terraform"
  nested_block_path    = ["required_providers"]
}
