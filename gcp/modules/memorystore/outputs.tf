output "host" {
  value = google_redis_instance.this.host
}

output "port" {
  value = google_redis_instance.this.port
}

output "auth_string" {
  value     = google_redis_instance.this.auth_string
  sensitive = true
}

output "ca_certificate" {
  description = "The CA that signs the server certificate when TLS is on (public, not a secret). Empty without TLS."
  value       = var.tls ? try(google_redis_instance.this.server_ca_certs[0].cert, "") : ""
}
