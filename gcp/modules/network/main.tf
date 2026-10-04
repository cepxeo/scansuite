###############################################################################
# VPC, private services access, and the workloads' way out.
#
# egress_mode = "nat": Cloud NAT with pinned egress addresses. They are worth
# pinning: they are what the workers present when they clone a customer
# repository and when they call an AI endpoint, so they end up in someone
# else's allowlist. They are reserved static IPs, never ephemeral.
#
# egress_mode = "none": no external address anywhere. The default internet
# route is not created; Google APIs (Vertex AI, Cloud Storage, the Cloud Run
# API the scan dispatch calls) are reached through Private Google Access on a
# private.googleapis.com or restricted.googleapis.com range, with private DNS
# zones pointing the API names at it. Anything else - internal Git hosts - is
# reached through the corporate connection the platform team attaches to this
# VPC, with names resolved through dns_forwarding_zones.
###############################################################################

locals {
  nat = var.egress_mode == "nat"

  # The two Private Google Access ranges. "restricted" serves only the APIs
  # VPC Service Controls supports, and is the one to use inside a perimeter.
  vip = {
    private    = { host = "private.googleapis.com.", range = "199.36.153.8/30", ips = ["199.36.153.8", "199.36.153.9", "199.36.153.10", "199.36.153.11"] }
    restricted = { host = "restricted.googleapis.com.", range = "199.36.153.4/30", ips = ["199.36.153.4", "199.36.153.5", "199.36.153.6", "199.36.153.7"] }
  }[var.google_apis_vip]

  # Names the workloads (googleapis.com) and internal browsers (run.app, the
  # web UI's Cloud Run URL) resolve to the range.
  api_zones = local.nat ? {} : {
    googleapis = "googleapis.com."
    run-app    = "run.app."
  }

  internal_ranges = concat([var.subnet_cidr], var.gke ? [var.pods_cidr, var.services_cidr] : [])
}

resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = "${var.prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  # No 0.0.0.0/0 route to the internet gateway: nothing in this network has a
  # way out except the Google APIs route below and the corporate connection.
  delete_default_routes_on_create = !local.nat
}

resource "google_compute_subnetwork" "nodes" {
  project       = var.project_id
  name          = "${var.prefix}-subnet"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.subnet_cidr

  # Workloads reach Google APIs (Cloud Storage, Vertex AI, the Cloud Run API)
  # without an external address.
  private_ip_google_access = true

  # Pod and service ranges exist for GKE only; on Cloud Run they would claim
  # address space (a /14) in a corporate plan for nothing.
  dynamic "secondary_ip_range" {
    for_each = var.gke ? { pods = var.pods_cidr, services = var.services_cidr } : {}
    content {
      range_name    = "${var.prefix}-${secondary_ip_range.key}"
      ip_cidr_range = secondary_ip_range.value
    }
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
  prefix_length = tonumber(split("/", var.psa_cidr)[1])
  address       = split("/", var.psa_cidr)[0]
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
# Cloud NAT (egress_mode = "nat")
###############################################################################

resource "google_compute_address" "nat" {
  count = local.nat ? var.nat_ip_count : 0

  project = var.project_id
  name    = "${var.prefix}-nat-${count.index + 1}"
  region  = var.region
}

resource "google_compute_router" "router" {
  count = local.nat ? 1 : 0

  project = var.project_id
  name    = "${var.prefix}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  count = local.nat ? 1 : 0

  project = var.project_id
  name    = "${var.prefix}-nat"
  router  = google_compute_router.router[0].name
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

moved {
  from = google_compute_router.router
  to   = google_compute_router.router[0]
}

moved {
  from = google_compute_router_nat.nat
  to   = google_compute_router_nat.nat[0]
}

###############################################################################
# Google APIs without the internet (egress_mode = "none")
###############################################################################

# Private Google Access needs a route to the API range through the default
# internet gateway; the traffic itself never leaves Google's network.
resource "google_compute_route" "google_apis" {
  count = local.nat ? 0 : 1

  project          = var.project_id
  name             = "${var.prefix}-google-apis"
  network          = google_compute_network.vpc.name
  dest_range       = local.vip.range
  next_hop_gateway = "default-internet-gateway"
  priority         = 100
}

resource "google_dns_managed_zone" "api" {
  for_each = local.api_zones

  project     = var.project_id
  name        = "${var.prefix}-${each.key}"
  dns_name    = each.value
  description = "Google APIs through ${trimsuffix(local.vip.host, ".")}"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.vpc.id
    }
  }
}

resource "google_dns_record_set" "api_wildcard" {
  for_each = local.api_zones

  project      = var.project_id
  managed_zone = google_dns_managed_zone.api[each.key].name
  name         = "*.${each.value}"
  type         = "CNAME"
  ttl          = 300
  rrdatas      = [local.vip.host]
}

resource "google_dns_record_set" "api_vip" {
  count = local.nat ? 0 : 1

  project      = var.project_id
  managed_zone = google_dns_managed_zone.api["googleapis"].name
  name         = local.vip.host
  type         = "A"
  ttl          = 300
  rrdatas      = local.vip.ips
}

###############################################################################
# Corporate DNS
###############################################################################

# Internal names (Git hosts, the registry) resolved by the corporate DNS
# servers, reached over the corporate connection.
resource "google_dns_managed_zone" "forwarding" {
  for_each = var.dns_forwarding_zones

  project     = var.project_id
  name        = "${var.prefix}-fwd-${replace(trimsuffix(each.key, "."), ".", "-")}"
  dns_name    = endswith(each.key, ".") ? each.key : "${each.key}."
  description = "Forwarded to the corporate DNS servers"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.vpc.id
    }
  }

  forwarding_config {
    dynamic "target_name_servers" {
      for_each = each.value
      content {
        ipv4_address    = target_name_servers.value
        forwarding_path = "private"
      }
    }
  }
}

# Inbound forwarders: addresses in the subnet the corporate DNS servers can
# forward run.app (the web UI's Cloud Run URL) to, so browsers resolve it to
# the Google APIs range above.
resource "google_dns_policy" "inbound" {
  count = var.dns_inbound_forwarding ? 1 : 0

  project                   = var.project_id
  name                      = "${var.prefix}-inbound"
  enable_inbound_forwarding = true

  networks {
    network_url = google_compute_network.vpc.id
  }
}

###############################################################################
# Firewall
###############################################################################

# Container-native load balancing sends health checks straight to pod IPs (GKE).
resource "google_compute_firewall" "health_checks" {
  count = var.gke ? 1 : 0

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

moved {
  from = google_compute_firewall.health_checks
  to   = google_compute_firewall.health_checks[0]
}

resource "google_compute_firewall" "internal" {
  project   = var.project_id
  name      = "${var.prefix}-allow-internal"
  network   = google_compute_network.vpc.name
  direction = "INGRESS"
  priority  = 1000

  source_ranges = local.internal_ranges

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
