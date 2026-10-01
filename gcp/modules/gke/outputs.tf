output "cluster_name" {
  value = google_container_cluster.this.name
}

output "endpoint" {
  value = google_container_cluster.this.endpoint
}

output "ca_certificate" {
  value     = try(google_container_cluster.this.master_auth[0].cluster_ca_certificate, "")
  sensitive = true
}

output "node_tag" {
  value = "${var.prefix}-node"
}

output "node_pools" {
  description = "Handle for depends_on - Kubernetes objects must not be created before there are nodes to run them."
  value = [
    google_container_node_pool.general.id,
    google_container_node_pool.scan_engine.id,
    google_container_node_pool.poc_sandbox.id,
  ]
}
