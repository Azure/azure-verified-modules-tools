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
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
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
  enabled = true
}

# disable for `locals.version.tf.json for now
rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_unused_required_providers" {
  enabled = true
}

rule "terraform_workspace_remote" {
  enabled = true
}

rule "avm_provider_modtm_version_constraint" {
  enabled = false
}

rule "avm_azapi_data_response_export_values_required" {
  enabled  = true
  severity = "notice"
}

rule "avm_azapi_response_export_values_required" {
  enabled  = true
  severity = "notice"
}

rule "avm_interface_ignore_body_changes" {
  enabled  = true
  severity = "notice"
}

rule "avm_interface_resource_types" {
  enabled  = true
  severity = "notice"
}

rule "avm_interface_retry" {
  enabled  = true
  severity = "notice"
}

rule "avm_interface_timeouts" {
  enabled  = true
  severity = "notice"
}

rule "avm_output_entire_resource_disallowed" {
  enabled  = true
  severity = "notice"
}

rule "avm_provider_azurerm_disallowed" {
  enabled  = true
  severity = "notice"
}
