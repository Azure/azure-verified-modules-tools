data "variable" "enable_telemetry" {
  name = "enable_telemetry"
}

data "data" "azurerm_client_config" {
  data_source_type = "azurerm_client_config"
}

data "data" "azapi_client_config" {
  data_source_type = "azapi_client_config"
}

data "data" "modtm_module_source" {
  data_source_type = "modtm_module_source"
}

data "resource" "random_uuid" {
  resource_type = "random_uuid"
}

data "resource" "modtm_telemetry" {
  resource_type = "modtm_telemetry"
}

data "resource" "terraform_data" {
  resource_type = "terraform_data"
}

data "resource" "azapi_resource" {
  resource_type = "azapi_resource"
}

data "resource" "all_resources" {}
data "data" "all_data" {}
data "terraform" "providers" {}

data "local" "main_location" {
  name = "main_location"
}

data "local" "avm_metadata" {
  name = "avm_metadata"
}

data "local" "avm_module_source_type" {
  name = "avm_module_source_type"
}

data "local" "avm_telemetry_version_token" {
  name = "avm_telemetry_version_token"
}

data "local" "avm_azapi_header" {
  name = "avm_azapi_header"
}

data "local" "legacy_azapi_helpers" {}

locals {
  enable_telemetry_exists    = length(data.variable.enable_telemetry.result) == 1
  main_location_exists       = length(data.local.main_location.result) == 1
  avm_metadata_exists        = length(data.local.avm_metadata.result) == 1
  module_source_type_exists  = length(data.local.avm_module_source_type.result) == 1
  version_token_exists       = length(data.local.avm_telemetry_version_token.result) == 1
  main_location_expression   = "var.location"
  azurerm_client_exists      = try(data.data.azurerm_client_config.result["azurerm_client_config"].telemetry != null, false)
  azapi_client_exists        = try(data.data.azapi_client_config.result["azapi_client_config"].telemetry != null, false)
  modtm_module_source_exists = try(data.data.modtm_module_source.result["modtm_module_source"].telemetry != null, false)
  random_uuid_exists         = try(data.resource.random_uuid.result["random_uuid"].telemetry != null, false)
  modtm_telemetry_exists     = try(data.resource.modtm_telemetry.result["modtm_telemetry"].telemetry != null, false)
  terraform_data_exists     = try(data.resource.terraform_data.result["terraform_data"].telemetry != null, false)
  azapi_resource_exists     = try(data.resource.azapi_resource.result["azapi_resource"].telemetry != null, false)
  modtm_provider_exists      = try(data.terraform.providers.required_providers.modtm != null, false)
  random_provider_exists     = try(data.terraform.providers.required_providers.random != null, false)

  legacy_deployment = try(data.resource.all_resources.result["azurerm_resource_group_template_deployment"].telemetry, null)
  legacy_deployment_exists = try(
    trimspace(local.legacy_deployment.count) == "var.enable_telemetry ? 1 : 0" &&
    trim(trimspace(local.legacy_deployment.deployment_mode), "\"") == "Incremental" &&
    trimspace(local.legacy_deployment.name) == "local.telem_arm_deployment_name" &&
    trimspace(local.legacy_deployment.template_content) == "local.telem_arm_template_content",
    false
  )
  legacy_random_id = try(data.resource.all_resources.result["random_id"].telem, null)
  legacy_random_root = try(local.legacy_random_id.mptf.module.abs_dir, null)
  legacy_reference_gap = "(?:[[:space:]]|/[*](?s:.*?)[*]/|//[^\\r\\n]*|#[^\\r\\n]*)*"
  legacy_random_referenced = local.legacy_random_root == null || local.legacy_random_root == "" ? true : (
    length(fileset(local.legacy_random_root, "*.tf.json")) > 0 ||
    anytrue([
      for filename in fileset(local.legacy_random_root, "*.tf") :
      length(regexall("(^|[^A-Za-z0-9_])random_id${local.legacy_reference_gap}[.]${local.legacy_reference_gap}telem([^A-Za-z0-9_]|$)", file("${local.legacy_random_root}/${filename}"))) > 0
    ])
  )
  legacy_random_id_exists = local.legacy_deployment_exists && try(
    trimspace(local.legacy_random_id.count) == "var.enable_telemetry ? 1 : 0" &&
    tostring(local.legacy_random_id.byte_length) == "4" &&
    !local.legacy_random_referenced,
    false
  )

  dangling_header_resources = {
    for name, resource in try(data.resource.azapi_resource.result["azapi_resource"], {}) :
    resource.mptf.block_address => resource
    if length(data.local.avm_azapi_header.result) == 0 && try(
      length(resource.mptf.module.abs_dir) > 0 &&
      length(fileset(resource.mptf.module.abs_dir, "*.tf.json")) == 0,
      false
    )
  }
  legacy_user_agent_expression = "var[.]enable_telemetry[[:space:]]*[?][[:space:]]*[{][[:space:]]*\"User-Agent\"[[:space:]]*[:=][[:space:]]*local[.]avm_azapi_header[[:space:]]*,?[[:space:]]*[}][[:space:]]*:[[:space:]]*"
  dangling_header_paths = {
    for address, resource in local.dangling_header_resources : address => [
      for header in ["create_headers", "read_headers", "update_headers", "delete_headers"] : header
      if can(regex("^${local.legacy_user_agent_expression}(null|[{][[:space:]]*[}])$", trimspace(try(resource[header], ""))))
    ]
  }
  dangling_if_match_headers = {
    for address, resource in local.dangling_header_resources : address => resource
    if can(regex(
      "^merge[(][[:space:]]*[{][[:space:]]*\"If-Match\"[[:space:]]*[:=][[:space:]]*\"[*]\"[[:space:]]*,?[[:space:]]*[}][[:space:]]*,[[:space:]]*${local.legacy_user_agent_expression}[{][[:space:]]*[}][[:space:]]*,?[[:space:]]*[)]$",
      trimspace(try(resource.delete_headers, ""))
    ))
  }

  legacy_header_definitions = {
    avm_azapi_header = "join(\" \", [for k, v in local.avm_azapi_headers : \"$${k}=$${v}\"])"
    avm_azapi_headers = <<-EOT
!var.enable_telemetry ? {} : (local.fork_avm ? {
  fork_avm  = "true"
  random_id = one(random_uuid.telemetry).result
  } : {
  avm                = "true"
  random_id          = one(random_uuid.telemetry).result
  avm_module_source  = one(data.modtm_module_source.telemetry).module_source
  avm_module_version = one(data.modtm_module_source.telemetry).module_version
})
EOT
    fork_avm = "!anytrue([for r in local.valid_module_source_regex : can(regex(r, one(data.modtm_module_source.telemetry).module_source))])"
    valid_module_source_regex = <<-EOT
[
  "registry.terraform.io/[A|a]zure/.+",
  "registry.opentofu.io/[A|a]zure/.+",
  "git::https://github\\.com/[A|a]zure/.+",
  "git::ssh:://git@github\\.com/[A|a]zure/.+",
]
EOT
  }
  legacy_header_values = {
    for name, definition in local.legacy_header_definitions :
    name => try(data.local.legacy_azapi_helpers.result[name], "")
  }
  legacy_header_bundle_matches = alltrue([
    for name, definition in local.legacy_header_definitions :
    trimspace(replace(replace(local.legacy_header_values[name], "\r\n", "\n"), "/(?m)^[\\t ]+/", "")) ==
    trimspace(replace(definition, "/(?m)^[\\t ]+/", ""))
  ])
  legacy_header_roots = try(distinct(concat(
    flatten([
      for resource_type, by_name in data.resource.all_resources.result : [
        for name, resource in by_name : resource.mptf.module.abs_dir
      ]
    ]),
    [for variable in values(data.variable.enable_telemetry.result) : variable.mptf.module.abs_dir]
  )), [])
  legacy_header_root = length(local.legacy_header_roots) == 1 ? local.legacy_header_roots[0] : null
  legacy_header_source_known = local.legacy_header_root == null || local.legacy_header_root == "" ? false : (
    length(fileset(local.legacy_header_root, "*.tf.json")) == 0 &&
    length(fileset(local.legacy_header_root, "*.tftest.json")) == 0 &&
    length(fileset(local.legacy_header_root, "tests/**/*.tftest.json")) == 0
  )
  legacy_header_source = local.legacy_header_bundle_matches && local.legacy_header_source_known ? join("\n", [
    for filename in concat(
      tolist(fileset(local.legacy_header_root, "*.tf")),
      tolist(fileset(local.legacy_header_root, "*.tftest.hcl")),
      tolist(fileset(local.legacy_header_root, "tests/**/*.tftest.hcl"))
    ) :
    file("${local.legacy_header_root}/${filename}")
  ]) : ""
  legacy_header_reference_patterns = {
    for name, definition in local.legacy_header_definitions :
    name => "(^|[^A-Za-z0-9_])local${local.legacy_reference_gap}[.]${local.legacy_reference_gap}${name}\\b"
  }
  legacy_header_assignment_patterns = {
    for name, definition in local.legacy_header_definitions :
    name => "(^|[^A-Za-z0-9_])${name}${local.legacy_reference_gap}=[^=]"
  }
  legacy_header_bundle_unused = (
    local.legacy_header_bundle_matches && local.legacy_header_source_known &&
    length(regexall("(^|[^A-Za-z0-9_])local${local.legacy_reference_gap}\\[", local.legacy_header_source)) == 0 &&
    alltrue([
      for name, pattern in local.legacy_header_reference_patterns :
      length(regexall(local.legacy_header_assignment_patterns[name], local.legacy_header_source)) ==
      1 + sum([for value in values(local.legacy_header_values) : length(regexall(local.legacy_header_assignment_patterns[name], value))]) &&
      length(regexall(pattern, local.legacy_header_source)) ==
      sum([for value in values(local.legacy_header_values) : length(regexall(pattern, value))])
    ])
  )

  other_modtm_resources = flatten([
    for resource_type, by_name in data.resource.all_resources.result : [
      for name, resource in by_name : name
      if startswith(resource_type, "modtm_") && !(resource_type == "modtm_telemetry" && name == "telemetry")
    ]
  ])
  other_modtm_data = flatten([
    for data_type, by_name in data.data.all_data.result : [
      for name, source in by_name : name
      if startswith(data_type, "modtm_") && !(data_type == "modtm_module_source" && name == "telemetry")
    ]
  ])
  other_random_resources = flatten([
    for resource_type, by_name in data.resource.all_resources.result : [
      for name, resource in by_name : name
      if startswith(resource_type, "random_") &&
      !(resource_type == "random_uuid" && name == "telemetry") &&
      !(local.legacy_random_id_exists && resource_type == "random_id" && name == "telem")
    ]
  ])
  other_random_data = flatten([
    for data_type, by_name in data.data.all_data.result : [
      for name, source in by_name : name
      if startswith(data_type, "random_")
    ]
  ])

  source_type_code_expression = <<-EOT
    (
      can(regex("^registry[.]terraform[.]io/", local.avm_module_source)) ? "t" :
      can(regex("^registry[.]opentofu[.]org/", local.avm_module_source)) ? "o" :
      can(regex("^git::", local.avm_module_source)) ? "g" :
      "x"
    )
EOT
}

transform "new_block" "new_enable_telemetry" {
  for_each       = !local.enable_telemetry_exists ? toset([1]) : toset([])
  new_block_type = "variable"
  labels         = ["enable_telemetry"]
  filename       = "variables.tf"
  asraw {
    type        = bool
    default     = true
    description = <<DESCRIPTION
This variable controls whether or not telemetry is enabled for the module.
For more information see <https://aka.ms/avm/telemetryinfo>.
If it is set to false, then no telemetry will be collected.
DESCRIPTION
    nullable    = false
  }
}

transform "update_in_place" "enable_telemetry" {
  for_each             = local.enable_telemetry_exists ? toset([1]) : toset([])
  target_block_address = "variable.enable_telemetry"
  asraw {
    type        = bool
    default     = true
    description = <<DESCRIPTION
This variable controls whether or not telemetry is enabled for the module.
For more information see <https://aka.ms/avm/telemetryinfo>.
If it is set to false, then no telemetry will be collected.
DESCRIPTION
    nullable    = false
  }
}

transform "remove_block" "azurerm_client_config" {
  for_each             = local.azurerm_client_exists ? toset([1]) : toset([])
  target_block_address = "data.azurerm_client_config.telemetry"
}

transform "new_block" "azapi_client_config" {
  for_each       = !local.azapi_client_exists ? toset([1]) : toset([])
  new_block_type = "data"
  labels         = ["azapi_client_config", "telemetry"]
  filename       = "main.telemetry.tf"
  asraw {
    count = var.enable_telemetry ? 1 : 0
  }
}

transform "update_in_place" "azapi_client_config" {
  for_each             = local.azapi_client_exists ? toset([1]) : toset([])
  target_block_address = "data.azapi_client_config.telemetry"
  asraw {
    count = var.enable_telemetry ? 1 : 0
  }
}

transform "remove_block" "modtm_module_source" {
  for_each             = local.modtm_module_source_exists ? toset([1]) : toset([])
  target_block_address = "data.modtm_module_source.telemetry"
}

transform "remove_block" "modtm_telemetry" {
  for_each             = local.modtm_telemetry_exists ? toset([1]) : toset([])
  target_block_address = "resource.modtm_telemetry.telemetry"
}

transform "regex_replace_expression" "legacy_telemetry_references" {
  for_each     = local.modtm_telemetry_exists ? toset([1]) : toset([])
  regex       = "modtm_telemetry[.]telemetry"
  replacement = "azapi_resource.telemetry"
  depends_on  = [transform.remove_block.modtm_telemetry]
}

transform "remove_block" "random_uuid" {
  for_each             = local.random_uuid_exists ? toset([1]) : toset([])
  target_block_address = "resource.random_uuid.telemetry"
}

transform "new_block" "forget_modtm_telemetry" {
  for_each       = local.modtm_telemetry_exists ? toset([1]) : toset([])
  new_block_type = "removed"
  filename       = "main.telemetry.tf"
  asraw {
    from = modtm_telemetry.telemetry
    lifecycle {
      destroy = false
    }
  }
  depends_on = [transform.regex_replace_expression.legacy_telemetry_references]
}

transform "new_block" "forget_random_uuid" {
  for_each       = local.random_uuid_exists ? toset([1]) : toset([])
  new_block_type = "removed"
  filename       = "main.telemetry.tf"
  asraw {
    from = random_uuid.telemetry
    lifecycle {
      destroy = false
    }
  }
  depends_on = [transform.remove_block.random_uuid]
}

transform "remove_block" "legacy_deployment" {
  for_each             = local.legacy_deployment_exists ? toset([1]) : toset([])
  target_block_address = "resource.azurerm_resource_group_template_deployment.telemetry"
}

transform "new_block" "forget_legacy_deployment" {
  for_each       = local.legacy_deployment_exists ? toset([1]) : toset([])
  new_block_type = "removed"
  filename       = "main.telemetry.tf"
  asraw {
    from = azurerm_resource_group_template_deployment.telemetry
    lifecycle {
      destroy = false
    }
  }
  depends_on = [transform.remove_block.legacy_deployment]
}

transform "remove_block" "legacy_random_id" {
  for_each             = local.legacy_random_id_exists ? toset([1]) : toset([])
  target_block_address = "resource.random_id.telem"
}

transform "new_block" "forget_legacy_random_id" {
  for_each       = local.legacy_random_id_exists ? toset([1]) : toset([])
  new_block_type = "removed"
  filename       = "main.telemetry.tf"
  asraw {
    from = random_id.telem
    lifecycle {
      destroy = false
    }
  }
  depends_on = [transform.remove_block.legacy_random_id]
}

transform "remove_block_element" "drop_modtm_provider" {
  for_each             = local.modtm_provider_exists && length(local.other_modtm_resources) == 0 && length(local.other_modtm_data) == 0 ? toset([1]) : toset([])
  target_block_address = "terraform"
  paths                = ["required_providers.modtm"]
  depends_on = [
    transform.remove_block.modtm_module_source,
    transform.remove_block.modtm_telemetry,
  ]
}

transform "remove_block_element" "drop_unused_random_provider" {
  for_each             = (local.random_uuid_exists || local.legacy_random_id_exists) && local.random_provider_exists && length(local.other_random_resources) == 0 && length(local.other_random_data) == 0 ? toset([1]) : toset([])
  target_block_address = "terraform"
  paths                = ["required_providers.random"]
  depends_on = [
    transform.remove_block.random_uuid,
    transform.remove_block.legacy_random_id,
  ]
}

transform "remove_block_element" "dangling_telemetry_headers" {
  for_each             = { for address, paths in local.dangling_header_paths : address => paths if length(paths) > 0 }
  target_block_address = each.key
  paths                = each.value
}

transform "update_in_place" "retain_delete_precondition" {
  for_each             = local.dangling_if_match_headers
  target_block_address = each.key
  asraw {
    delete_headers = { "If-Match" = "*" }
  }
}

transform "remove_block_element" "unused_legacy_header_helpers" {
  for_each             = local.legacy_header_bundle_unused ? toset(keys(local.legacy_header_definitions)) : toset([])
  target_block_address = "local.${each.value}"
  paths                = [each.value]
}

transform "ensure_local" "main_location" {
  for_each           = !local.main_location_exists ? toset([1]) : toset([])
  name               = "main_location"
  fallback_file_name = "main.telemetry.tf"
  value_as_string    = local.main_location_expression
}

transform "update_in_place" "main_location" {
  for_each             = local.main_location_exists ? toset([1]) : toset([])
  target_block_address = "local.main_location"
  asstring {
    main_location = local.main_location_expression
  }
}

transform "new_block" "telemetry_locals" {
  for_each       = !local.avm_metadata_exists ? toset([1]) : toset([])
  new_block_type = "locals"
  filename       = "main.telemetry.tf"
  asraw {
    avm_metadata                = jsondecode(file("${path.module}/metadata.json"))
    avm_telemetry_manifest_path = "${path.root}/.terraform/modules/modules.json"
    avm_telemetry_modules       = fileexists(local.avm_telemetry_manifest_path) ? jsondecode(file(local.avm_telemetry_manifest_path)).Modules : []
    avm_telemetry_module_entry  = try(one([for module in local.avm_telemetry_modules : module if module.Dir == path.module]), null)
    avm_module_version          = try(local.avm_telemetry_module_entry.Version, "")
    avm_module_source           = try(local.avm_telemetry_module_entry.Source, "")
  }
}

transform "ensure_local" "avm_module_source_type" {
  for_each           = !local.module_source_type_exists ? toset([1]) : toset([])
  name               = "avm_module_source_type"
  fallback_file_name = "main.telemetry.tf"
  value_as_string    = trim(local.source_type_code_expression, "\r\n")
  depends_on         = [transform.new_block.telemetry_locals]
}

transform "update_in_place" "avm_module_source_type" {
  for_each             = local.module_source_type_exists ? toset([1]) : toset([])
  target_block_address = "local.avm_module_source_type"
  asstring {
    avm_module_source_type = trim(local.source_type_code_expression, "\r\n")
  }
}

transform "ensure_local" "avm_telemetry_version_token" {
  for_each           = !local.version_token_exists ? toset([1]) : toset([])
  name               = "avm_telemetry_version_token"
  fallback_file_name = "main.telemetry.tf"
  value_as_string    = "replace(coalesce(local.avm_module_version, \"0.0.0\"), \".\", \"-\")"
  depends_on         = [transform.new_block.telemetry_locals]
}

transform "new_block" "terraform_data" {
  for_each       = !local.terraform_data_exists ? toset([1]) : toset([])
  new_block_type = "resource"
  labels         = ["terraform_data", "telemetry"]
  filename       = "main.telemetry.tf"
  asraw {
    count = var.enable_telemetry ? 1 : 0
  }
}

transform "update_in_place" "terraform_data" {
  for_each             = local.terraform_data_exists ? toset([1]) : toset([])
  target_block_address = "resource.terraform_data.telemetry"
  asraw {
    count = var.enable_telemetry ? 1 : 0
  }
}

transform "new_block" "azapi_resource" {
  for_each       = !local.azapi_resource_exists ? toset([1]) : toset([])
  new_block_type = "resource"
  labels         = ["azapi_resource", "telemetry"]
  filename       = "main.telemetry.tf"
  asraw {
    count     = var.enable_telemetry ? 1 : 0
    type      = "Microsoft.Resources/deployments@2025-04-01"
    name      = "${local.avm_metadata.telemetryIdPrefix}.${local.avm_telemetry_version_token}.${local.avm_module_source_type}.${substr(sha1(terraform_data.telemetry[0].id), 0, 4)}"
    parent_id = one(data.azapi_client_config.telemetry).subscription_resource_id
    location  = local.main_location
    response_export_values = []
    body = {
      properties = {
        mode = "Incremental"
        template = {
          "$schema"      = "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#"
          contentVersion = "1.0.0.0"
          resources      = []
          outputs = {
            telemetry = {
              type  = "String"
              value = "For more information, see https://aka.ms/avm/TelemetryInfo"
            }
            apply_id = {
              type  = "String"
              value = plantimestamp()
            }
          }
        }
      }
    }
    lifecycle {
      precondition {
        condition     = length(local.avm_metadata.telemetryIdPrefix) + length(local.avm_telemetry_version_token) + 8 <= 64 && can(regex("^[A-Za-z0-9_-]+$", local.avm_telemetry_version_token))
        error_message = "The telemetry deployment name must fit Azure's 64-character limit and contain a valid module version."
      }
    }
  }
}

transform "update_in_place" "azapi_resource" {
  for_each             = local.azapi_resource_exists ? toset([1]) : toset([])
  target_block_address = "resource.azapi_resource.telemetry"
  asraw {
    count     = var.enable_telemetry ? 1 : 0
    type      = "Microsoft.Resources/deployments@2025-04-01"
    name      = "${local.avm_metadata.telemetryIdPrefix}.${local.avm_telemetry_version_token}.${local.avm_module_source_type}.${substr(sha1(terraform_data.telemetry[0].id), 0, 4)}"
    parent_id = one(data.azapi_client_config.telemetry).subscription_resource_id
    location  = local.main_location
    response_export_values = []
    body = {
      properties = {
        mode = "Incremental"
        template = {
          "$schema"      = "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#"
          contentVersion = "1.0.0.0"
          resources      = []
          outputs = {
            telemetry = {
              type  = "String"
              value = "For more information, see https://aka.ms/avm/TelemetryInfo"
            }
            apply_id = {
              type  = "String"
              value = plantimestamp()
            }
          }
        }
      }
    }
    lifecycle {
      precondition {
        condition     = length(local.avm_metadata.telemetryIdPrefix) + length(local.avm_telemetry_version_token) + 8 <= 64 && can(regex("^[A-Za-z0-9_-]+$", local.avm_telemetry_version_token))
        error_message = "The telemetry deployment name must fit Azure's 64-character limit and contain a valid module version."
      }
    }
  }
}

transform "remove_block_element" "drop_legacy_telemetry_tags" {
  for_each             = local.azapi_resource_exists && try(data.resource.azapi_resource.result["azapi_resource"].telemetry.tags != null, false) ? toset([1]) : toset([])
  target_block_address = "resource.azapi_resource.telemetry"
  paths                = ["tags"]
  depends_on           = [transform.update_in_place.azapi_resource]
}
