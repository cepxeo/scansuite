output "name" {
  value = azurerm_container_registry.this.name
}

output "login_server" {
  value = azurerm_container_registry.this.login_server
}

output "pull_ready" {
  description = "Depend on this before an app pulls from the registry."
  value       = [for grant in azurerm_role_assignment.pull : grant.id]
}
