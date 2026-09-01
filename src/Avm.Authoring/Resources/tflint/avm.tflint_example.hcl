plugin "terraform" {
  enabled = true
  version = "0.15.0"
  source  = "github.com/terraform-linters/tflint-ruleset-terraform"
}

plugin "avm" {
  enabled   = true
  version   = "1.0.0"
  source    = "github.com/Azure/tflint-ruleset-avm"
  signature = "attestation"
}

rule "terraform_comment_syntax" {
  enabled = true
}

rule "terraform_deprecated_index" {
  enabled = true
}

rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_deprecated_lookup" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = false
}

rule "terraform_documented_variables" {
  enabled = false
}

rule "terraform_empty_list_equality" {
  enabled = true
}

rule "terraform_module_pinned_source" {
  enabled = true
}

rule "terraform_module_version" {
  enabled = true
  exact = true
}

rule "terraform_naming_convention" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_standard_module_structure" {
  enabled = false
}

rule "terraform_typed_variables" {
  enabled = false
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_unused_required_providers" {
  enabled = true
}

rule "terraform_workspace_remote" {
  enabled = true
}

rule "avm_terraform_literal_heredoc_disallowed" {
  enabled = false
}

rule "avm_terraform_provider_block_disallowed" {
  enabled = false
}

rule "avm_terraform_sensitive_variable_default_disallowed" {
  enabled = false
}

rule "avm_azapi_resource_tags_required" {
  enabled = false
}

rule "avm_azapi_replace_triggers_refs_valid" {
  enabled = false
}

rule "avm_azapi_response_export_values_required" {
  enabled  = false
  severity = "notice"
}

rule "avm_azapi_data_response_export_values_required" {
  enabled  = true
  severity = "notice"
}

# AVM Provider Rules

rule "avm_terraform_configuration_file_required" {
  enabled = false
}

# AVM Module Rules

rule "avm_terraform_module_source_required" {
  enabled = false
}

# AVM Output Rules

rule "avm_output_resource_id_required" {
  enabled = false
}

rule "avm_output_entire_resource_disallowed" {
  enabled  = true
  severity = "notice"
}

# AVM Variable Interface Rules

rule "avm_interface_customer_managed_key" {
  enabled = false
}

rule "avm_interface_lock_deprecated" {
  enabled = false
}

rule "avm_interface_private_endpoints_deprecated" {
  enabled = false
}

rule "avm_interface_role_assignments_deprecated" {
  enabled = false
}

rule "avm_interface_diagnostic_settings" {
  enabled = false
}

rule "avm_interface_ignore_body_changes" {
  enabled  = false
  severity = "notice"
}

rule "avm_interface_location" {
  enabled = false
}

rule "avm_interface_lock" {
  enabled = false
}

rule "avm_interface_managed_identities" {
  enabled = false
}

rule "avm_interface_private_endpoints" {
  enabled = false
}

rule "avm_interface_private_endpoints_manage_dns_zone_group" {
  enabled = false
}

rule "avm_interface_resource_types" {
  enabled  = false
  severity = "notice"
}

rule "avm_interface_retry" {
  enabled  = false
  severity = "notice"
}

rule "avm_interface_role_assignments" {
  enabled = false
}

rule "avm_interface_tags" {
  enabled = false
}

rule "avm_interface_timeouts" {
  enabled  = false
  severity = "notice"
}

rule "avm_provider_modtm_version_constraint" {
  enabled = false
}

rule "avm_provider_azurerm_disallowed" {
  enabled  = true
  severity = "notice"
}
