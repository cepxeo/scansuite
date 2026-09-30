output "workspace_id" {
  value = azurerm_log_analytics_workspace.this.id
}

output "workspace_customer_id" {
  description = "The workspace GUID, for queries."
  value       = azurerm_log_analytics_workspace.this.workspace_id
}

output "action_group_id" {
  value = one(azurerm_monitor_action_group.email[*].id)
}
