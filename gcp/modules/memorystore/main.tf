###############################################################################
# Memorystore for Redis - Celery broker and result backend.
#
# Two deliberate choices:
#
#  * TLS on (var.tls): SERVER_AUTHENTICATION on port 6378. Every client builds
#    its URL through configuration.services.redis_uri(), which speaks rediss://
#    with REDIS_TLS and verifies the server against the instance's own CA
#    (REDIS_CA_CERTS, written to a file at container start). Turning it on or
#    off replaces the instance, losing whatever is queued at that moment.
#
#  * not Redis Cluster. Celery's redis transport does not support cluster mode.
###############################################################################

resource "google_redis_instance" "this" {
  project        = var.project_id
  name           = "${var.prefix}-redis"
  region         = var.region
  tier           = var.highly_available ? "STANDARD_HA" : "BASIC"
  memory_size_gb = var.memory_gb
  redis_version  = "REDIS_7_2"
  labels         = var.labels

  location_id             = var.primary_zone
  authorized_network      = var.network_id
  connect_mode            = "PRIVATE_SERVICE_ACCESS"
  auth_enabled            = true
  transit_encryption_mode = var.tls ? "SERVER_AUTHENTICATION" : "DISABLED"

  # The broker holds queued scans. Losing it silently loses work, so keep
  # snapshots and never evict.
  dynamic "persistence_config" {
    for_each = var.highly_available ? [1] : []
    content {
      persistence_mode    = "RDB"
      rdb_snapshot_period = "SIX_HOURS"
    }
  }

  redis_configs = {
    maxmemory-policy = "noeviction"
  }

  maintenance_policy {
    weekly_maintenance_window {
      day = "SUNDAY"
      start_time {
        hours   = 4
        minutes = 0
      }
    }
  }
}
