###############################################################################
# Log Analytics for every container's stdout, and the alert destination.
#
# The applications log to stdout (LOG_FILE=/dev/stdout), so their lines land in
# ContainerAppConsoleLogs_CL as unstructured text - the same shape the GCP
# log-based metrics parse.
###############################################################################

resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.prefix}-logs"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = var.daily_quota_gb
  tags                = var.tags
}

resource "azurerm_monitor_action_group" "email" {
  count               = var.alert_email != "" ? 1 : 0
  name                = "${var.prefix}-alerts"
  resource_group_name = var.resource_group_name
  short_name          = "scansuite"
  tags                = var.tags

  email_receiver {
    name                    = "operators"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}
