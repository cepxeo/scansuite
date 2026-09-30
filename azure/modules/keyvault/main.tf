###############################################################################
# Key Vault: the canonical copy of every generated credential.
#
# RBAC mode, and every reader is granted per secret rather than per vault. That
# is what keeps worker-poc - which runs model-written code - away from the
# licence and the wrapping keys even with its own token (the GCP secret sets,
# infra/main.tf, give the same property). Container Apps reads the secrets by
# reference through each workload's identity, so no value is copied into an
# app definition.
###############################################################################

resource "azurerm_key_vault" "this" {
  name                       = "${var.prefix}-kv-${var.suffix}"
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tenant_id                  = var.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = var.purge_protection
  soft_delete_retention_days = 7
  tags                       = var.tags

  # Container Apps reaches the vault over its public endpoint with its managed
  # identity, and Terraform writes the secrets through it from the operator's
  # machine. Every read and write still needs an Entra ID token and an RBAC role.
  public_network_access_enabled = true
}

# Terraform writes the secrets, so the operator needs the data plane.
resource "azurerm_role_assignment" "operator" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.operator_principal_id
}

# Role assignments take a while to reach the data plane.
resource "time_sleep" "operator_rbac" {
  depends_on      = [azurerm_role_assignment.operator]
  create_duration = "60s"
}

resource "azurerm_key_vault_secret" "this" {
  for_each = toset(var.secret_names)

  name         = each.value
  value        = var.secrets[each.value]
  key_vault_id = azurerm_key_vault.this.id
  content_type = "text/plain"

  depends_on = [time_sleep.operator_rbac]
}

locals {
  # "secret/reader" -> {secret, reader}; keys are static so for_each can plan
  # before the identities exist.
  grants = merge([
    for secret, readers in var.readers : {
      for reader in readers : "${secret}/${reader}" => { secret = secret, reader = reader }
    }
  ]...)
}

resource "azurerm_role_assignment" "reader" {
  for_each = local.grants

  scope                = "${azurerm_key_vault.this.id}/secrets/${azurerm_key_vault_secret.this[each.value.secret].name}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.principals[each.value.reader]
  principal_type       = "ServicePrincipal"
}
