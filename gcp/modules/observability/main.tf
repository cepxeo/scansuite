###############################################################################
# Logging, uptime, and the alerts that matter for a scanner platform.
#
# Application logs arrive here for free because LOG_FILE is set to /dev/stdout:
# logging.basicConfig still writes to a "file", the platform's logging agent
# picks it up, and nothing in the code had to change.  Which resource type they
# arrive as depends on the platform, hence local.log_resource.
###############################################################################

resource "google_monitoring_notification_channel" "email" {
  count = var.alert_email != "" ? 1 : 0

  project      = var.project_id
  display_name = "ScanSuite alerts"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }
}

locals {
  channels = google_monitoring_notification_channel.email[*].id
  host     = var.domain_name != "" ? var.domain_name : var.lb_ip

  # The same application logs from two different resource types depending on
  # where it runs, so the log-based metrics have to filter accordingly.
  log_resource = var.platform == "cloudrun" ? join(" OR ", [
    "resource.type=\"cloud_run_revision\"",
    "resource.type=\"cloud_run_job\"",
    "resource.type=\"cloud_run_worker_pool\"",
    ]) : join(" AND ", [
    "resource.type=\"k8s_container\"",
    "resource.labels.namespace_name=\"scansuite\"",
  ])

  # Alerting on a log-based metric needs the resource type named in its filter
  # too, or Monitoring refuses the policy.
  metric_resource = var.platform == "cloudrun" ? "resource.type = one_of(\"cloud_run_revision\", \"cloud_run_job\", \"cloud_run_worker_pool\")" : "resource.type = \"k8s_container\""

  # Container restarts are a Kubernetes concept.  On Cloud Run the equivalent
  # signal is a scan that stopped reporting, which the application's own orphan
  # sweep already detects and logs.
  restart_alerts = var.platform == "gke" ? 1 : 0
}

###############################################################################
# Log-based metric
#
# The application logs "<timestamp>:LEVEL:message" as plain text on stdout, so
# Cloud Logging sees no structured severity. Match the level in the payload.
###############################################################################

resource "google_logging_metric" "app_errors" {
  project = var.project_id
  name    = "${var.prefix}/application_errors"

  filter = <<-EOT
    ${local.log_resource}
    textPayload=~":(ERROR|CRITICAL):"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "storage_failures" {
  project = var.project_id
  name    = "${var.prefix}/object_storage_failures"

  # object_store.py swallows upload errors and prints them. Silent data loss is
  # the worst failure mode this system has, so give it its own metric.
  filter = <<-EOT
    ${local.log_resource}
    textPayload=~"Error (on file upload to|deleting .* from) GCP storage"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

###############################################################################
# Uptime
###############################################################################

resource "google_monitoring_uptime_check_config" "web" {
  count = var.internal_only ? 0 : 1

  project      = var.project_id
  display_name = "${var.prefix}-web"
  timeout      = "10s"
  period       = "300s"

  http_check {
    path         = "/log_in"
    port         = 443
    use_ssl      = true
    validate_ssl = var.domain_name != "" # a self-signed certificate cannot validate

    # Google's probers come from addresses web_allowed_cidrs does not list;
    # Cloud Armor admits requests carrying this header instead.
    headers = {
      "X-ScanSuite-Uptime" = var.uptime_token
    }
    mask_headers = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = local.host
    }
  }

  lifecycle {
    # mask_headers makes the API return the token masked, which would read as
    # a change on every apply. The token itself never changes once generated.
    ignore_changes = [http_check[0].headers]
  }
}

resource "google_monitoring_alert_policy" "uptime" {
  count = var.internal_only ? 0 : 1

  project      = var.project_id
  display_name = "ScanSuite unreachable"
  combiner     = "OR"

  conditions {
    display_name = "Uptime check failing"

    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.web[0].uptime_check_id}\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "300s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.channels
}

###############################################################################
# Alerts
###############################################################################

resource "google_monitoring_alert_policy" "app_errors" {
  project      = var.project_id
  display_name = "ScanSuite application errors"
  combiner     = "OR"

  conditions {
    display_name = "More than 10 ERROR lines in 5 minutes"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.app_errors.name}\" AND ${local.metric_resource}"
      comparison      = "COMPARISON_GT"
      threshold_value = 10
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = local.channels
}

resource "google_monitoring_alert_policy" "storage_failures" {
  project      = var.project_id
  display_name = "ScanSuite artifact upload failures"
  combiner     = "OR"

  conditions {
    display_name = "Any object storage failure"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.storage_failures.name}\" AND ${local.metric_resource}"
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = local.channels
}

resource "google_monitoring_alert_policy" "cloudsql_cpu" {
  project      = var.project_id
  display_name = "ScanSuite database CPU"
  combiner     = "OR"

  conditions {
    display_name = "Cloud SQL CPU above 80% for 15 minutes"

    condition_threshold {
      filter          = "metric.type=\"cloudsql.googleapis.com/database/cpu/utilization\" AND resource.type=\"cloudsql_database\" AND resource.label.database_id=\"${var.project_id}:${var.cloudsql_instance}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      duration        = "900s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = local.channels
}

resource "google_monitoring_alert_policy" "cloudsql_disk" {
  project      = var.project_id
  display_name = "ScanSuite database disk"
  combiner     = "OR"

  conditions {
    display_name = "Cloud SQL disk above 85%"

    condition_threshold {
      filter          = "metric.type=\"cloudsql.googleapis.com/database/disk/utilization\" AND resource.type=\"cloudsql_database\" AND resource.label.database_id=\"${var.project_id}:${var.cloudsql_instance}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.85
      duration        = "600s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = local.channels
}

resource "google_monitoring_alert_policy" "redis_memory" {
  project      = var.project_id
  display_name = "ScanSuite broker memory"
  combiner     = "OR"

  conditions {
    display_name = "Memorystore above 75% - maxmemory-policy is noeviction, so a full broker rejects writes"

    condition_threshold {
      filter          = "metric.type=\"redis.googleapis.com/stats/memory/usage_ratio\" AND resource.type=\"redis_instance\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.75
      duration        = "600s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = local.channels
}

resource "google_monitoring_alert_policy" "scan_engine_restarts" {
  count = local.restart_alerts

  project      = var.project_id
  display_name = "ScanSuite scan engine restarting"
  combiner     = "OR"

  conditions {
    display_name = "A scan engine container restarted - any running scan died with it"

    condition_threshold {
      filter          = "metric.type=\"kubernetes.io/container/restart_count\" AND resource.type=\"k8s_container\" AND resource.label.namespace_name=\"scansuite\" AND resource.label.pod_name=monitoring.regex.full_match(\"scan-engine-.*\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_DELTA"
      }
    }
  }

  notification_channels = local.channels
}

resource "google_monitoring_alert_policy" "scratch_disk" {
  count = local.restart_alerts

  project      = var.project_id
  display_name = "ScanSuite scratch volume filling up"
  combiner     = "OR"

  conditions {
    display_name = "Scan scratch or Docker image cache above 80%"

    condition_threshold {
      filter          = "metric.type=\"kubernetes.io/pod/volume/utilization\" AND resource.type=\"k8s_pod\" AND resource.label.namespace_name=\"scansuite\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      duration        = "600s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = local.channels
}
