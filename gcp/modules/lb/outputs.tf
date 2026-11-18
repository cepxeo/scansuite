output "ip_address" {
  value = google_compute_global_address.lb.address
}

output "security_policy" {
  value = google_compute_security_policy.this.name
}

output "dns_name_servers" {
  description = "Delegate these at your registrar when manage_dns is on."
  value       = flatten(google_dns_managed_zone.this[*].name_servers)
}

output "certificate_mode" {
  value = var.domain_name != "" ? "google-managed (${var.domain_name})" : "self-signed (IP only)"
}
