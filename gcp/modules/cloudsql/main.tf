###############################################################################
# Cloud SQL for PostgreSQL.
#
# PostgreSQL 16 rather than the 13 in docker-compose: 13 is end-of-life
# upstream. The schema is created and changed by the migrate job (Alembic),
# which does not depend on the server's version.
###############################################################################

resource "google_sql_database_instance" "this" {
  project          = var.project_id
  name             = var.name != "" ? var.name : "${var.prefix}-pg"
  region           = var.region
  database_version = "POSTGRES_16"

  deletion_protection = var.deletion_protection

  settings {
    tier              = var.tier
    edition           = "ENTERPRISE"
    availability_type = var.highly_available ? "REGIONAL" : "ZONAL"
    disk_type         = "PD_SSD"
    disk_size         = var.disk_gb
    disk_autoresize   = true
    user_labels       = var.labels

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "02:00"
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = 14
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = 7 # Sunday
      hour         = 3
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = true
    }

    database_flags {
      name  = "max_connections"
      value = "400"
    }

    # Every process opens pool_size 10 + max_overflow 20. Long scans hold
    # connections for hours, so do not let the server reap them early.
    database_flags {
      name  = "idle_in_transaction_session_timeout"
      value = "3600000"
    }
  }

  lifecycle {
    ignore_changes = [settings[0].disk_size]
  }
}

resource "google_sql_database" "scansuite" {
  project  = var.project_id
  name     = "scansuite"
  instance = google_sql_database_instance.this.name
}

resource "google_sql_user" "scansuite" {
  project  = var.project_id
  name     = "scansuite"
  instance = google_sql_database_instance.this.name
  password = var.db_password

  # PostgreSQL will not drop a role that owns objects, and this one owns the
  # whole schema, so deleting it through the API fails on teardown. The user
  # goes with the instance anyway.
  deletion_policy = "ABANDON"
}
