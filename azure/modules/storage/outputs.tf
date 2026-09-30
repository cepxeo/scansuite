output "artifacts_account_url" {
  value = azurerm_storage_account.artifacts.primary_blob_endpoint
}

output "artifacts_container" {
  value = azurerm_storage_container.artifacts.name
}

output "writer_ready" {
  value = azurerm_role_assignment.artifacts_writer.id
}
