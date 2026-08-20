plugin "terraform" {
  enabled = true
  version = "0.15.0"
  source  = "github.com/terraform-linters/tflint-ruleset-terraform"
}

plugin "avm" {
  enabled   = true
  version   = "0.21.0"
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

rule "terraform_heredoc_usage" {
  enabled = false
}

rule "terraform_module_provider_declaration" {
  enabled = false
}

rule "terraform_sensitive_variable_no_default" {
  enabled = false
}

rule "azapi_resource_tag" {
  enabled = false
}

rule "azapi_replace_triggers_refs" {
  enabled = false
}

rule "azapi_response_export_values" {
  enabled = false
}

# AVM Provider Rules

rule "terraform_tf_file" {
  enabled = false
}

# AVM Module Rules

rule "required_module_source_tffr1" {
  enabled = false
}

# AVM Output Rules

rule "required_output_rmfr7" {
  enabled = false
}

# AVM Variable Interface Rules

rule "customer_managed_key" {
  enabled = false
}

rule "deprecated_lock_interface" {
  enabled = false
}

rule "deprecated_private_endpoints_interface" {
  enabled = false
}

rule "deprecated_role_assignments_interface" {
  enabled = false
}

rule "diagnostic_settings" {
  enabled = false
}

rule "ignore_body_changes" {
  enabled = false
}

rule "location" {
  enabled = false
}

rule "lock" {
  enabled = false
}

rule "managed_identities" {
  enabled = false
}

rule "private_endpoints" {
  enabled = false
}

rule "private_endpoints_manage_dns_zone_group" {
  enabled = false
}

rule "resource_types" {
  enabled = false
}

rule "retry" {
  enabled = false
}

rule "role_assignments" {
  enabled = false
}

rule "tags" {
  enabled = false
}

rule "timeouts" {
  enabled = false
}

rule "provider_modtm_version_constraint" {
  enabled = false
}
