locals {
  test_settings = var.repository_creation_mode_enabled || var.bami_test_settings == null ? {
    tenant_id             = ""
    client_id             = ""
    test_subscription_ids = []
    } : {
    tenant_id = var.bami_test_settings.tenant_id
    client_id = module.bami[0].client_id
    test_subscription_ids = [
      for subscription in var.bami_test_settings.test_subscription_ids : {
        name = subscription.name
        id   = subscription.id
      } if try(subscription.tag, "General") == "General"
    ]
  }

  label_list = jsondecode(file(var.github_labels_source_path)).labels
  standard_labels = { for label in local.label_list : label.name => {
    name        = trimspace(label.name)
    color       = label.color
    description = trimspace(try(label.githubDescription, label.description))
  } }

  release_version_labels = var.release_metadata_check == "off" ? {} : {
    patch = {
      name        = "patch"
      color       = "C2E0C6"
      description = "Release a patch version: backwards-compatible bug fixes."
    }
    minor = {
      name        = "minor"
      color       = "FBCA04"
      description = "Release a minor version: new features, or breaking changes before 1.0.0."
    }
    major = {
      name        = "major"
      color       = "B60205"
      description = "Release a major version: breaking changes from 1.0.0 onwards."
    }
  }

  labels = merge(local.standard_labels, local.release_version_labels)

  release_metadata_check_required = var.release_metadata_check == "required"
}
