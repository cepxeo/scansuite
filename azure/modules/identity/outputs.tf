output "app" {
  value = {
    id           = azurerm_user_assigned_identity.app.id
    client_id    = azurerm_user_assigned_identity.app.client_id
    principal_id = azurerm_user_assigned_identity.app.principal_id
  }
}

output "poc" {
  value = {
    id           = azurerm_user_assigned_identity.poc.id
    client_id    = azurerm_user_assigned_identity.poc.client_id
    principal_id = azurerm_user_assigned_identity.poc.principal_id
  }
}

output "migrate" {
  value = {
    id           = azurerm_user_assigned_identity.migrate.id
    client_id    = azurerm_user_assigned_identity.migrate.client_id
    principal_id = azurerm_user_assigned_identity.migrate.principal_id
  }
}

output "dispatcher_role_definition_id" {
  value = azurerm_role_definition.dispatcher.role_definition_resource_id
}
