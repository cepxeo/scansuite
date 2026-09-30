output "resource_group" {
  value = azurerm_resource_group.this.name
}

output "url" {
  description = "The web UI. Only the addresses in web_allowed_cidrs can reach it when that list is set."
  value       = module.workloads.web_fqdn != null ? "https://${module.workloads.web_fqdn}" : null
}

output "registry" {
  description = "deploy.sh imports the images here."
  value       = module.registry.name
}

output "migrate_job_name" {
  value = module.workloads.migrate_job_name
}

output "sast_job_name" {
  value = module.workloads.sast_job_name
}

output "environment_name" {
  value = module.environment.name
}

output "environment_static_ip" {
  description = "Inbound address of the environment."
  value       = module.environment.static_ip
}

output "egress_ip" {
  description = "Static egress address (enable_nat_gateway), for allowlists at git hosts and model endpoints."
  value       = module.network.egress_ip
}

output "key_vault" {
  value = module.keyvault.vault_name
}

output "postgres_fqdn" {
  value = module.postgres.fqdn
}

output "log_analytics_workspace_id" {
  description = "Workspace GUID for az monitor log-analytics query / the REST query API."
  value       = module.monitoring.workspace_customer_id
}

output "image_registry" {
  description = "Where deploy.sh imports teams-web, teams-worker and teams-worker-poc from."
  value       = var.image_registry
}

output "image_tag" {
  value = var.image_tag
}
