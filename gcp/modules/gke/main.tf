###############################################################################
# Regional GKE Standard cluster with three purpose-built node pools:
#
#   general      web, worker-admin and celery-beat. Spans all three zones
#                because the load balancer is wired to zonal NEGs, and a NEG
#                only exists in a zone that has nodes.
#   scan-engine  the static analysis workers. Pinned to one zone: each replica
#                carries a zonal persistent disk for repository clones.
#   poc-sandbox  gVisor. Runs model-generated exploit code, so it gets a second
#                kernel boundary.
#
# Autopilot is close to viable now that no workload needs a privileged
# container, and it would remove the node pools from your plate. What it costs
# you is GKE Sandbox: Autopilot will not run gVisor, so worker-poc would
# execute model-written code behind nothing but a container boundary. That is
# the trade to weigh if you ever want to make the switch.
###############################################################################

resource "google_service_account" "nodes" {
  project      = var.project_id
  account_id   = "${var.prefix}-nodes"
  display_name = "ScanSuite GKE nodes"
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_container_cluster" "this" {
  provider = google-beta

  project  = var.project_id
  name     = "${var.prefix}-cluster"
  location = var.region

  # Node pools are managed separately; the default one only exists to get the
  # control plane created.
  remove_default_node_pool = true
  initial_node_count       = 1
  node_locations           = var.zones

  deletion_protection = var.deletion_protection
  networking_mode     = "VPC_NATIVE"
  network             = var.network_name
  subnetwork          = var.subnet_name
  datapath_provider   = "ADVANCED_DATAPATH" # Dataplane V2: NetworkPolicy without a separate addon

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range
    services_secondary_range_name = var.services_range
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_cidrs
      content {
        cidr_block   = cidr_blocks.value
        display_name = "authorized-${cidr_blocks.key}"
      }
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = true
    }
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  dynamic "database_encryption" {
    for_each = var.database_encryption_key != null ? [1] : []
    content {
      state    = "ENCRYPTED"
      key_name = var.database_encryption_key
    }
  }

  # A scan can run for hours; do not let an automatic upgrade land in the
  # middle of the working day.
  maintenance_policy {
    recurring_window {
      start_time = "2024-01-01T01:00:00Z"
      end_time   = "2024-01-01T05:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }

  resource_labels = var.labels

  lifecycle {
    ignore_changes = [node_locations]
  }
}

###############################################################################
# Node pools
###############################################################################

locals {
  common_node_config = {
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

resource "google_container_node_pool" "general" {
  project        = var.project_id
  name           = "general"
  location       = var.region
  cluster        = google_container_cluster.this.name
  node_locations = var.zones

  autoscaling {
    min_node_count = 1
    max_node_count = 2
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type    = var.general_machine_type
    image_type      = "COS_CONTAINERD"
    disk_size_gb    = 100
    disk_type       = "pd-balanced"
    service_account = local.common_node_config.service_account
    oauth_scopes    = local.common_node_config.oauth_scopes
    tags            = ["${var.prefix}-node"]
    labels          = merge(var.labels, { pool = "general" })

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}

resource "google_container_node_pool" "scan_engine" {
  project        = var.project_id
  name           = "scan-engine"
  location       = var.region
  cluster        = google_container_cluster.this.name
  node_locations = [var.primary_zone]

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Never evict a running scan to make room for a node upgrade.
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type    = var.scan_engine_machine_type
    image_type      = "COS_CONTAINERD"
    disk_size_gb    = 100
    disk_type       = "pd-balanced"
    service_account = local.common_node_config.service_account
    oauth_scopes    = local.common_node_config.oauth_scopes
    tags            = ["${var.prefix}-node", "${var.prefix}-scan-engine"]
    labels          = merge(var.labels, { pool = "scan-engine" })

    taint {
      key    = "workload"
      value  = "scan-engine"
      effect = "NO_SCHEDULE"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}

resource "google_container_node_pool" "poc_sandbox" {
  # sandbox_config (gVisor) is only exposed by the beta provider.
  provider = google-beta

  project        = var.project_id
  name           = "poc-sandbox"
  location       = var.region
  cluster        = google_container_cluster.this.name
  node_locations = [var.primary_zone]

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.poc_machine_type
    image_type      = "COS_CONTAINERD"
    disk_size_gb    = 100
    disk_type       = "pd-balanced"
    service_account = local.common_node_config.service_account
    oauth_scopes    = local.common_node_config.oauth_scopes
    tags            = ["${var.prefix}-node"]
    labels          = merge(var.labels, { pool = "poc-sandbox" })

    # gVisor. GKE adds its own sandbox.gke.io/runtime taint on top of this one.
    sandbox_config {
      sandbox_type = "gvisor"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}
