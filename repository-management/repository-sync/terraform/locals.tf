locals {
  test_settings = var.repository_creation_mode_enabled ? {
    tenant_id             = ""
    client_id             = ""
    test_subscription_ids = []
    } : (var.bami_test_settings == null ? {
      tenant_id             = module.azure[0].tenant_id
      client_id             = module.azure[0].client_id
      test_subscription_ids = var.test_subscription_ids
      } : {
      tenant_id             = var.bami_test_settings.tenant_id
      client_id             = var.bami_test_settings.client_id
      test_subscription_ids = var.bami_test_settings.test_subscription_ids
  })

  label_list = csvdecode(file(var.github_labels_source_path))
  labels = { for label in local.label_list : label.Name => {
    name        = trimspace(label.Name)
    color       = label.HEX
    description = strcontains(label.Description, ":") ? trimspace(replace(split(":", split(".", label.Description)[0])[1], "this", "This")) : trimspace(label.Description)
  } }
}
