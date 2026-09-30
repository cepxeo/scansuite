provider "azurerm" {
  subscription_id = var.subscription_id

  # Storage data-plane calls use Entra ID: the storage accounts have shared
  # keys switched off.
  storage_use_azuread = true

  # Register only what this configuration uses (deploy.sh registers
  # Microsoft.App), instead of every provider the azurerm default list names.
  resource_provider_registrations = "none"

  features {
    key_vault {
      # Dev: destroy.sh purges, so a rebuilt deployment can reuse the names.
      # Prod keeps soft-deleted vaults and secrets recoverable.
      purge_soft_delete_on_destroy    = var.environment != "prod"
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = var.environment == "prod"
    }
    log_analytics_workspace {
      # A soft-deleted workspace keeps its name for 14 days; dev rebuilds must
      # not trip over it.
      permanently_delete_on_destroy = var.environment != "prod"
    }
  }
}

data "azurerm_client_config" "current" {}
