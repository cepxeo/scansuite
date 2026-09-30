###############################################################################
# PostgreSQL Flexible Server 16, private access only.
#
# One database account: the application connects as the schema owner, with no
# separate runtime role. Team isolation is the application's job, not the
# database's: there is no row-level security, so the BYPASSRLS the admin holds
# through azure_pg_admin changes nothing. The admin is not a superuser.
#
# Two server parameters the application depends on:
#   azure.extensions   pg_trgm, created by the vulndb migration. Anything not
#                      on this list is refused at CREATE EXTENSION.
#   idle_in_transaction_session_timeout
#                      long scans hold connections for hours; the same one hour
#                      the Cloud SQL configuration sets.
###############################################################################

resource "azurerm_private_dns_zone" "this" {
  name                = "${var.prefix}.private.postgres.database.azure.com"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  name                 = "${var.prefix}-pg-link"
  private_dns_zone_id  = azurerm_private_dns_zone.this.id
  virtual_network_id   = var.vnet_id
  registration_enabled = false
  tags                 = var.tags
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                          = "${var.prefix}-pg-${var.suffix}"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  version                       = "16"
  sku_name                      = var.sku_name
  storage_mb                    = var.storage_mb
  auto_grow_enabled             = true
  backup_retention_days         = var.highly_available ? 14 : 7
  delegated_subnet_id           = var.subnet_id
  private_dns_zone_id           = azurerm_private_dns_zone.this.id
  public_network_access_enabled = false
  administrator_login           = var.administrator_login
  administrator_password        = var.administrator_password
  tags                          = var.tags

  authentication {
    password_auth_enabled         = true
    active_directory_auth_enabled = false
  }

  dynamic "high_availability" {
    for_each = var.highly_available ? [1] : []
    content {
      mode = "ZoneRedundant"
    }
  }

  maintenance_window {
    day_of_week  = 0
    start_hour   = 3
    start_minute = 0
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.this]

  lifecycle {
    # Azure picks and may move the zone (HA failover); do not fight it.
    ignore_changes = [zone, high_availability[0].standby_availability_zone]
  }
}

resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "PG_TRGM"
}

resource "azurerm_postgresql_flexible_server_configuration" "idle_in_transaction" {
  name      = "idle_in_transaction_session_timeout"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "3600000"
}

resource "azurerm_postgresql_flexible_server_database" "scansuite" {
  name      = "scansuite"
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}
