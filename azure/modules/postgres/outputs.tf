output "server_id" {
  value = azurerm_postgresql_flexible_server.this.id
}

output "server_name" {
  value = azurerm_postgresql_flexible_server.this.name
}

output "fqdn" {
  value = azurerm_postgresql_flexible_server.this.fqdn
}

output "database_name" {
  value = azurerm_postgresql_flexible_server_database.scansuite.name
}

output "ready" {
  description = "Depend on this before anything connects: the parameters must be applied first."
  value = [
    azurerm_postgresql_flexible_server_configuration.extensions.id,
    azurerm_postgresql_flexible_server_configuration.idle_in_transaction.id,
  ]
}
