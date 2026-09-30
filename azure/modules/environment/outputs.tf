output "id" {
  value = azurerm_container_app_environment.this.id
}

output "name" {
  value = azurerm_container_app_environment.this.name
}

output "default_domain" {
  value = azurerm_container_app_environment.this.default_domain
}

output "static_ip" {
  value = azurerm_container_app_environment.this.static_ip_address
}

output "scan_profile_name" {
  description = "Workload profile the scan job runs on."
  value       = var.dedicated_scan_profile ? "scan" : "Consumption"
}
