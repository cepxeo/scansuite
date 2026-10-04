output "network_id" {
  value = google_compute_network.vpc.id
}
output "network_name" {
  value = google_compute_network.vpc.name
}
output "subnet_name" {
  value = google_compute_subnetwork.nodes.name
}
output "pods_range_name" {
  value = var.gke ? "${var.prefix}-pods" : ""
}
output "services_range_name" {
  value = var.gke ? "${var.prefix}-services" : ""
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
