output "vault_id" {
  value = azurerm_key_vault.this.id
}

output "vault_name" {
  value = azurerm_key_vault.this.name
}

output "secret_ids" {
  description = "Secret name -> versionless id, for Container Apps secret references (always the latest version)."
  value       = { for name, secret in azurerm_key_vault_secret.this : name => secret.versionless_id }
}

output "grants_ready" {
  description = "Depend on this before anything reads a secret by reference."
  value       = [for grant in azurerm_role_assignment.reader : grant.id]
}
