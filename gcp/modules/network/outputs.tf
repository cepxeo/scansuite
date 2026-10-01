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
  value = google_compute_subnetwork.nodes.secondary_ip_range[0].range_name
}

output "services_range_name" {
  value = google_compute_subnetwork.nodes.secondary_ip_range[1].range_name
}

output "nat_ip_addresses" {
  value = google_compute_address.nat[*].address
}

output "psa_connection" {
  description = "Handle for depends_on - Cloud SQL and Memorystore must not be created before the peering exists."
  value       = google_service_networking_connection.psa.id
}
