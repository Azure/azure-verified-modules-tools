locals {
  # Resource names must remain discoverable after the bootstrap state is discarded.
  storage_account_name          = coalesce(var.storage_account_name, "stavmstate${substr(sha256("${lower(var.subscription_id)}/${lower(var.resource_group_name)}"), 0, 14)}")
  federated_subject             = "repository_owner_id:${var.github_repository_owner_id}:repository_id:${var.github_repository_id}:environment:avm"
  blob_data_contributor_role_id = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe"
}

module "state_resource_group" {
  source  = "Azure/avm-res-resources-resourcegroup/azurerm"
  version = "0.4.0"

  name             = var.resource_group_name
  location         = var.location
  enable_telemetry = false
  tags             = var.tags
}

module "backend_identity" {
  source  = "Azure/avm-res-managedidentity-userassignedidentity/azurerm"
  version = "0.5.2"

  name                = var.backend_identity_name
  location            = var.location
  resource_group_name = module.state_resource_group.name
  enable_telemetry    = false
  tags                = var.tags

  federated_identity_credentials = {
    github_avm = {
      name     = "github-avm"
      issuer   = "https://token.actions.githubusercontent.com"
      audience = ["api://AzureADTokenExchange"]
      subject  = local.federated_subject
    }
  }
}

module "state_storage" {
  source  = "Azure/avm-res-storage-storageaccount/azurerm"
  version = "0.10.0"

  name             = local.storage_account_name
  location         = var.location
  parent_id        = module.state_resource_group.resource_id
  enable_telemetry = false
  tags             = var.tags

  account_kind                     = "StorageV2"
  account_sku_name                 = "Standard_ZRS"
  access_tier                      = "Hot"
  allow_nested_items_to_be_public  = false
  cross_tenant_replication_enabled = false
  default_to_oauth_authentication  = true
  shared_access_key_enabled        = false
  https_traffic_only_enabled       = true
  min_tls_version                  = "TLS1_2"
  is_hns_enabled                   = false
  nfsv3_enabled                    = false
  sftp_enabled                     = false
  local_user_enabled               = false

  # GitHub-hosted runners use the public endpoint, but every blob request needs Entra ID and RBAC.
  public_network_access_enabled = true
  network_rules = {
    bypass         = ["None"]
    default_action = "Allow"
  }

  blob_properties = {
    versioning_enabled = true
    delete_retention_policy = {
      enabled                = true
      days                   = var.soft_delete_retention_days
      allow_permanent_delete = false
    }
    container_delete_retention_policy = {
      enabled = true
      days    = var.soft_delete_retention_days
    }
  }

  # AVM 0.10 uses ARM for containers and RBAC; bootstrap needs no storage data-plane grant.
  role_assignment_definition_lookup_enabled = false
  containers = {
    tfstate = {
      name          = var.container_name
      public_access = "None"
      role_assignments = {
        backend_state_access = {
          role_definition_id_or_name = local.blob_data_contributor_role_id
          principal_id               = module.backend_identity.principal_id
          principal_type             = "ServicePrincipal"
          description                = "Repository-sync backend access to this Terraform state container only."
        }
      }
    }
  }

  lock = var.enable_delete_lock ? {
    kind = "CanNotDelete"
    name = "protect-state-storage"
  } : null
}
