output "network_id" {
  value = google_compute_network.vpc.id
}
output "network_name" {
  value = google_compute_network.vpc.name
}
output "subnet_name" {
  value = google_compute_subnetwork.nodes.name
}
output "poc_subnet_name" {
  value = google_compute_subnetwork.poc.name
}
output "poc_runner_denied" {
  description = "The PoC runner's egress deny rule: the tags it applies to and the ranges it closes."
  value = {
    target_tags        = google_compute_firewall.poc_runner_deny.target_tags
    destination_ranges = google_compute_firewall.poc_runner_deny.destination_ranges
    direction          = google_compute_firewall.poc_runner_deny.direction
  }
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
