###############################################################################
# Azure Container Registry.
#
# deploy.sh imports the published images into it (az acr import, server side,
# with Docker Hub credentials from the environment rather than Terraform
# state), so the apps pull from here as their managed identity and never meet
# Docker Hub's anonymous rate limit.
###############################################################################

resource "azurerm_container_registry" "this" {
  name                = "${var.prefix}acr${var.suffix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = var.sku
  admin_enabled       = false
  tags                = var.tags
}

resource "azurerm_role_assignment" "pull" {
  for_each = var.pull_principals

  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = each.value
  principal_type       = "ServicePrincipal"
}
