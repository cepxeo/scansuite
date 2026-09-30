###############################################################################
# The artifact store: the Blob container behind database/object_store.py's
# azblob: provider (packed sources, AI SAST checkpoints, reports). Shared keys
# off - the app identity is the only writer - versioned, and reachable only
# from the Container Apps subnet.
#
# There is no scratch share: repository clones stay on each scan replica's own
# disk. A premium NFS share was 100-600 times slower for clones and source
# reads in testing.
###############################################################################

resource "azurerm_storage_account" "artifacts" {
  name                            = "${var.prefix}art${var.suffix}"
  location                        = var.location
  resource_group_name             = var.resource_group_name
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = var.replication_type
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  tags                            = var.tags

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }

  network_rules {
    default_action             = "Deny"
    bypass                     = ["AzureServices"]
    virtual_network_subnet_ids = [var.aca_subnet_id]
  }
}

resource "azurerm_storage_container" "artifacts" {
  name                  = "artifacts"
  storage_account_id    = azurerm_storage_account.artifacts.id
  container_access_type = "private"
}

# Overwritten and deleted artifacts keep a version for retention_days; at most
# a handful of versions of a hot object survive in any case.
resource "azurerm_storage_management_policy" "artifacts" {
  storage_account_id = azurerm_storage_account.artifacts.id

  rule {
    name    = "expire-old-versions"
    enabled = true

    filters {
      blob_types = ["blockBlob"]
    }

    actions {
      version {
        delete_after_days_since_creation = var.retention_days
      }
    }
  }
}

resource "azurerm_role_assignment" "artifacts_writer" {
  scope                = "${azurerm_storage_account.artifacts.id}/blobServices/default/containers/${azurerm_storage_container.artifacts.name}"
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.writer_principal_id
  principal_type       = "ServicePrincipal"
}
