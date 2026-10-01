###############################################################################
# VPC, private services access, Cloud NAT with pinned egress addresses.
#
# The egress addresses are worth pinning: they are what the workers present when
# they clone a customer repository and when they call Vertex AI, so they end up
# in someone else's allowlist. They are reserved static IPs, never ephemeral.
###############################################################################

resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = "${var.prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "nodes" {
  project       = var.project_id
  name          = "${var.prefix}-subnet"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.subnet_cidr

  # Private nodes reach Google APIs (Cloud SQL admin, GCS, Vertex, Artifact
  # Registry) without traversing Cloud NAT.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "${var.prefix}-pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "${var.prefix}-services"
    ip_cidr_range = var.services_cidr
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

###############################################################################
# Private Service Access - Cloud SQL and Memorystore live in this range
###############################################################################

resource "google_compute_global_address" "psa" {
  project       = var.project_id
  name          = "${var.prefix}-psa-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  address       = "10.30.0.0"
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa.name]

  # Cloud SQL goes on using the peering for a while after its instance is
  # deleted, so deleting the connection fails on teardown. The peering goes
  # with the network.
  deletion_policy = "ABANDON"
}

###############################################################################
# Cloud NAT
###############################################################################

resource "google_compute_address" "nat" {
  count = var.nat_ip_count

  project = var.project_id
  name    = "${var.prefix}-nat-${count.index + 1}"
  region  = var.region
}

resource "google_compute_router" "router" {
  project = var.project_id
  name    = "${var.prefix}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  project = var.project_id
  name    = "${var.prefix}-nat"
  router  = google_compute_router.router.name
  region  = var.region

  nat_ip_allocate_option = "MANUAL_ONLY"
  nat_ips                = google_compute_address.nat[*].self_link

  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  # Cloning large repositories and streaming model calls both open many
  # concurrent connections. Give each VM a generous port block and let it grow.
  enable_dynamic_port_allocation = true
  min_ports_per_vm               = 1024
  max_ports_per_vm               = 32768

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

###############################################################################
# Firewall
###############################################################################

# Container-native load balancing sends health checks straight to pod IPs.
resource "google_compute_firewall" "health_checks" {
  project   = var.project_id
  name      = "${var.prefix}-allow-health-checks"
  network   = google_compute_network.vpc.name
  direction = "INGRESS"
  priority  = 900

  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["${var.prefix}-node"]

  allow {
    protocol = "tcp"
    ports    = ["5000"]
  }
}

resource "google_compute_firewall" "internal" {
  project   = var.project_id
  name      = "${var.prefix}-allow-internal"
  network   = google_compute_network.vpc.name
  direction = "INGRESS"
  priority  = 1000

  source_ranges = [var.subnet_cidr, var.pods_cidr, var.services_cidr]

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}

# Deliberately NOT added here: an egress deny that stops the workers reaching
# RFC1918 space. It reads like an obvious hardening win, but the worker's own
# dependencies - Cloud SQL and Memorystore on the PSA range, kube-dns on the
# pod range - live in exactly those ranges, so a blanket deny takes the
# platform down. Restricting which repositories may be cloned belongs in the
# application, not in a VPC firewall. See README, "Hardening you should layer
# on".
