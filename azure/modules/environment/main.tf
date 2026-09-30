###############################################################################
# The Container Apps environment: the boundary every app and job runs in.
#
# Workload-profile environment on the delegated subnet, logs to Log Analytics.
# It depends on nothing but the network and the workspace, so Terraform
# creates it - about 25 minutes, the longest step - alongside the database and
# the vault instead of after them.
#
# The optional Dedicated profile (prod) gives scans 4 vCPU / 32 GiB, which
# Consumption cannot (4 / 8); with minimum 0 nodes it costs nothing while no
# scan runs.
###############################################################################

resource "azurerm_container_app_environment" "this" {
  name                               = "${var.prefix}-env"
  location                           = var.location
  resource_group_name                = var.resource_group_name
  infrastructure_subnet_id           = var.subnet_id
  infrastructure_resource_group_name = "${var.resource_group_name}-aca-managed"
  internal_load_balancer_enabled     = var.internal
  logs_destination                   = "log-analytics"
  log_analytics_workspace_id         = var.log_analytics_workspace_id
  tags                               = var.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  dynamic "workload_profile" {
    for_each = var.dedicated_scan_profile ? [1] : []
    content {
      name                  = "scan"
      workload_profile_type = "E4"
      minimum_count         = 0
      maximum_count         = var.dedicated_scan_max_nodes
    }
  }
}
