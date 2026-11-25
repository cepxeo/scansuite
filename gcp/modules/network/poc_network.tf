###############################################################################
# The PoC runner's own VPC (poc_network = "own", the default)
#
# The poc job runs model-written code as an identity with no roles. Here it
# runs in a VPC of its own: no peering (Cloud SQL, Memorystore), no connection
# to the corporate network, nothing of the installation's VPC. What it can
# reach is decided by its routes, which no firewall policy can add to:
#
#   egress_mode = "nat"   a route to the internet through a Cloud NAT of its
#                         own, on its own reserved address: the targets on the
#                         internet, and nothing private (the internet gateway
#                         carries no private destination).
#   egress_mode = "none"  a route to the Google APIs range only: the signed
#                         URLs of its input and result, nothing else. PoCs
#                         cannot reach targets; use poc_network = "shared" for
#                         internal targets over the corporate connection.
#
# A firewall rule in the VPC repeats the same boundary where no hierarchical
# policy decides first.
###############################################################################

locals {
  poc_own = var.poc_network == "own"

  # Ranges the runner's firewall closes with egress_mode = "nat": the private
  # and shared address space (no route reaches them anyway) and whatever
  # poc_denied_ranges adds.
  poc_private_ranges = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"]
}

resource "google_compute_network" "poc" {
  count = local.poc_own ? 1 : 0

  project                 = var.project_id
  name                    = "${var.prefix}-poc-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  description             = "The PoC runner job alone: no peering, no corporate connection."

  # The routes below are the only ones: the internet with egress_mode = "nat",
  # Google APIs with "none".
  delete_default_routes_on_create = true
}

# Not named like the shared subnet (<prefix>-poc-subnet): subnet names are unique
# per region, and the shared one may still exist while the job moves here.
resource "google_compute_subnetwork" "poc_own" {
  count = local.poc_own ? 1 : 0

  project       = var.project_id
  name          = "${var.prefix}-poc-runner-subnet"
  region        = var.region
  network       = google_compute_network.poc[0].id
  ip_cidr_range = var.poc_subnet_cidr

  # The runner reads its input and writes its result through signed Cloud
  # Storage URLs.
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# egress_mode = "nat": the internet through the runner's own NAT.

resource "google_compute_route" "poc_internet" {
  count = local.poc_own && local.nat ? 1 : 0

  project          = var.project_id
  name             = "${var.prefix}-poc-internet"
  network          = google_compute_network.poc[0].name
  dest_range       = "0.0.0.0/0"
  next_hop_gateway = "default-internet-gateway"
  priority         = 1000
}

# Not one of the workers' NAT addresses: a NAT address serves one gateway, and
# the PoCs should not present the address customers allowlisted for cloning.
resource "google_compute_address" "poc_nat" {
  count = local.poc_own && local.nat ? 1 : 0

  project = var.project_id
  name    = "${var.prefix}-poc-nat-1"
  region  = var.region
}

resource "google_compute_router" "poc" {
  count = local.poc_own && local.nat ? 1 : 0

  project = var.project_id
  name    = "${var.prefix}-poc-router"
  region  = var.region
  network = google_compute_network.poc[0].id
}

resource "google_compute_router_nat" "poc" {
  count = local.poc_own && local.nat ? 1 : 0

  project = var.project_id
  name    = "${var.prefix}-poc-nat"
  router  = google_compute_router.poc[0].name
  region  = var.region

  nat_ip_allocate_option             = "MANUAL_ONLY"
  nat_ips                            = google_compute_address.poc_nat[*].self_link
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  enable_dynamic_port_allocation = true
  min_ports_per_vm               = 1024
  max_ports_per_vm               = 16384

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_firewall" "poc_deny_private" {
  count = local.poc_own && local.nat ? 1 : 0

  project            = var.project_id
  name               = "${var.prefix}-poc-deny-private"
  network            = google_compute_network.poc[0].name
  direction          = "EGRESS"
  priority           = 900
  destination_ranges = concat(local.poc_private_ranges, var.poc_denied_ranges)
  description        = "The PoC runner's VPC: no private address, nor the ranges of poc_denied_ranges."

  deny { protocol = "all" }
}

# egress_mode = "none": Google APIs only.

resource "google_compute_route" "poc_google_apis" {
  count = local.poc_own && !local.nat ? 1 : 0

  project          = var.project_id
  name             = "${var.prefix}-poc-google-apis"
  network          = google_compute_network.poc[0].name
  dest_range       = local.vip.range
  next_hop_gateway = "default-internet-gateway"
  priority         = 100
}

resource "google_dns_managed_zone" "poc_googleapis" {
  count = local.poc_own && !local.nat ? 1 : 0

  project     = var.project_id
  name        = "${var.prefix}-poc-googleapis"
  dns_name    = "googleapis.com."
  description = "Google APIs through ${trimsuffix(local.vip.host, ".")}, for the PoC runner's VPC"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.poc[0].id
    }
  }
}

resource "google_dns_record_set" "poc_googleapis_wildcard" {
  count = local.poc_own && !local.nat ? 1 : 0

  project      = var.project_id
  managed_zone = google_dns_managed_zone.poc_googleapis[0].name
  name         = "*.googleapis.com."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = [local.vip.host]
}

resource "google_dns_record_set" "poc_googleapis_vip" {
  count = local.poc_own && !local.nat ? 1 : 0

  project      = var.project_id
  managed_zone = google_dns_managed_zone.poc_googleapis[0].name
  name         = local.vip.host
  type         = "A"
  ttl          = 300
  rrdatas      = local.vip.ips
}

resource "google_compute_firewall" "poc_deny_all" {
  count = local.poc_own && !local.nat ? 1 : 0

  project            = var.project_id
  name               = "${var.prefix}-poc-egress-deny"
  network            = google_compute_network.poc[0].name
  direction          = "EGRESS"
  priority           = 1000
  destination_ranges = ["0.0.0.0/0"]
  description        = "The PoC runner's VPC: everything but Google APIs (the next rule) is denied."

  deny { protocol = "all" }
}

resource "google_compute_firewall" "poc_allow_google_apis" {
  count = local.poc_own && !local.nat ? 1 : 0

  project            = var.project_id
  name               = "${var.prefix}-poc-egress-google-apis"
  network            = google_compute_network.poc[0].name
  direction          = "EGRESS"
  priority           = 900
  destination_ranges = [local.vip.range]
  description        = "The PoC runner's VPC: Google APIs (the signed URLs)."

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}
