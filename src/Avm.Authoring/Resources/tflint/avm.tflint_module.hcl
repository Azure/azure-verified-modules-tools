config {
  disabled_by_default = true
}

plugin "terraform" {
  enabled = true
  version = "0.12.0"
  source  = "github.com/terraform-linters/tflint-ruleset-terraform"
}

plugin "avm" {
  enabled   = true
  version   = "0.18.0"
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

rule "terraform_heredoc_usage" {
  enabled = true
}

rule "terraform_module_provider_declaration" {
  enabled = true
}

rule "terraform_output_separate" {
  enabled = true
}

rule "terraform_required_providers_declaration" {
  enabled = true
}

rule "terraform_required_version_declaration" {
  enabled = true
}

rule "terraform_sensitive_variable_no_default" {
  enabled = true
}

rule "terraform_variable_nullable_false" {
  enabled = true
}

rule "terraform_variable_separate" {
  enabled = true
}

rule "azurerm_resource_tag" {
  enabled = true
}

# AVM Provider Rules

rule "tfnfr26" {
  enabled = true
}

# AVM Module Rules

rule "required_module_source_tffr1" {
  enabled = true
}

# AVM Output Rules

rule "required_output_rmfr7" {
  enabled = true
}

# AVM Variable Interface Rules

rule "customer_managed_key" {
  enabled = true
}

rule "diagnostic_settings" {
  enabled = true
}

rule "location" {
  enabled = true
}

rule "lock" {
  enabled = true
}

rule "managed_identities" {
  enabled = true
}

rule "private_endpoints" {
  enabled = true
}

rule "role_assignments" {
  enabled = true
}

rule "tags" {
  enabled = true
}

rule "provider_modtm_version_constraint" {
  enabled = false
}
