locals {
  test_settings = var.repository_creation_mode_enabled || var.bami_test_settings == null ? {
    tenant_id             = ""
    client_id             = ""
    test_subscription_ids = []
    } : {
    tenant_id             = var.bami_test_settings.tenant_id
    client_id             = module.bami[0].client_id
    test_subscription_ids = var.bami_test_settings.test_subscription_ids
  }

  label_list = jsondecode(file(var.github_labels_source_path)).labels
  labels = { for label in local.label_list : label.name => {
    name        = trimspace(label.name)
    color       = label.color
    description = trimspace(try(label.githubDescription, label.description))
  } }
}
