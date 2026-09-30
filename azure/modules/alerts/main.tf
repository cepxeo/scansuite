###############################################################################
# Alerts, the counterpart of infra/modules/observability.
#
#   app-errors     a burst of ":ERROR:" lines from any container (the log format
#                  every process uses, logging.basicConfig(format=...:%(levelname)s:...)).
#   storage-errors object-store failures ("Error on file upload", "Failed to
#                  retrieve file", ...), which the application only prints.
#   scan-failed    a scan job execution that ended Failed.
#   postgres-cpu   sustained database CPU.
###############################################################################

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "app_errors" {
  name                 = "${var.prefix}-app-errors"
  location             = var.location
  resource_group_name  = var.resource_group_name
  scopes               = [var.workspace_id]
  severity             = 2
  evaluation_frequency = "PT15M"
  window_duration      = "PT15M"
  description          = "More than 20 ERROR lines from ScanSuite containers in 15 minutes."
  tags                 = var.tags

  criteria {
    query                   = <<-KQL
      ContainerAppConsoleLogs_CL
      | where Log_s has ":ERROR:"
      | summarize errors = count()
    KQL
    time_aggregation_method = "Total"
    metric_measure_column   = "errors"
    operator                = "GreaterThan"
    threshold               = 20
  }

  action {
    action_groups = [var.action_group_id]
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "storage_errors" {
  name                 = "${var.prefix}-storage-errors"
  location             = var.location
  resource_group_name  = var.resource_group_name
  scopes               = [var.workspace_id]
  severity             = 2
  evaluation_frequency = "PT15M"
  window_duration      = "PT15M"
  description          = "Object storage failures reported by database/object_store.py."
  tags                 = var.tags

  criteria {
    query                   = <<-KQL
      ContainerAppConsoleLogs_CL
      | where Log_s has_any ("Error on file upload", "Failed to retrieve file", "Error deleting file", "Error creating Azure Blob storage client")
      | summarize failures = count()
    KQL
    time_aggregation_method = "Total"
    metric_measure_column   = "failures"
    operator                = "GreaterThan"
    threshold               = 0
  }

  action {
    action_groups = [var.action_group_id]
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "scan_failed" {
  name                 = "${var.prefix}-scan-execution-failed"
  location             = var.location
  resource_group_name  = var.resource_group_name
  scopes               = [var.workspace_id]
  severity             = 3
  evaluation_frequency = "PT15M"
  window_duration      = "PT15M"
  description          = "A scan job execution ended with a non-zero exit (work_job.py exits 1 or 2)."
  tags                 = var.tags

  criteria {
    query                   = <<-KQL
      ContainerAppSystemLogs_CL
      | where JobName_s endswith "-sast" and Reason_s == "ContainerTerminated" and Log_s !has "exit code '0'" and Log_s !has "ManuallyStopped"
      | summarize failed = count()
    KQL
    time_aggregation_method = "Total"
    metric_measure_column   = "failed"
    operator                = "GreaterThan"
    threshold               = 0
  }

  action {
    action_groups = [var.action_group_id]
  }
}

resource "azurerm_monitor_metric_alert" "postgres_cpu" {
  name                = "${var.prefix}-postgres-cpu"
  resource_group_name = var.resource_group_name
  scopes              = [var.postgres_server_id]
  description         = "Database CPU above 80 % for 15 minutes."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "cpu_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = var.action_group_id
  }
}
