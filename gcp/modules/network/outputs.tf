output "network_id" {
  value = google_compute_network.vpc.id
}
output "network_name" {
  value = google_compute_network.vpc.name
}
output "subnet_name" {
  value = google_compute_subnetwork.nodes.name
}
output "poc_network_name" {
  description = "The PoC runner job's VPC: its own (<prefix>-poc-vpc), or this one with poc_network = \"shared\"."
  value       = local.poc_own ? google_compute_network.poc[0].name : google_compute_network.vpc.name
}
output "poc_subnet_name" {
  value = local.poc_own ? google_compute_subnetwork.poc_own[0].name : google_compute_subnetwork.poc[0].name
}
output "poc_routes" {
  description = "Destinations of the routes in the PoC runner's own VPC; null with poc_network = \"shared\"."
  value = local.poc_own ? concat(
    google_compute_route.poc_internet[*].dest_range,
    google_compute_route.poc_google_apis[*].dest_range,
  ) : null
}
output "poc_nat_ip_addresses" {
  description = "The address PoCs reach internet targets from (own VPC, egress_mode = \"nat\"); with \"shared\" they use nat_ip_addresses."
  value       = google_compute_address.poc_nat[*].address
}
output "poc_runner_denied" {
  description = "The PoC runner's egress deny rule: the tags it applies to and the ranges it closes."
  value = local.poc_shared ? {
    target_tags        = google_compute_firewall.poc_runner_deny[0].target_tags
    destination_ranges = google_compute_firewall.poc_runner_deny[0].destination_ranges
    direction          = google_compute_firewall.poc_runner_deny[0].direction
    } : one([for rule in concat(google_compute_firewall.poc_deny_private, google_compute_firewall.poc_deny_all) : {
      target_tags        = rule.target_tags
      destination_ranges = rule.destination_ranges
      direction          = rule.direction
  }])
}
output "nat_ip_addresses" {
  description = "Empty with egress_mode = \"none\"."
  value       = google_compute_address.nat[*].address
}
output "google_apis_range" {
  description = "The Private Google Access range the API names resolve to, with egress_mode = \"none\"; empty otherwise."
  value       = var.egress_mode == "none" ? local.vip.range : ""
}
output "psa_connection" {
  description = "Handle for depends_on - Cloud SQL and Memorystore must not be created before the peering exists."
  value       = google_service_networking_connection.psa.id
}

output "internet_route" {
  description = "The route to the internet that egress_mode = \"nat\" keeps (destination and priority), or null."
  value       = one([for route in google_compute_route.internet : { dest_range = route.dest_range, priority = route.priority }])
}
