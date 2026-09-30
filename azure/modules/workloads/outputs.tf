output "redis_host" {
  value = azurerm_container_app.redis.name
}

output "web_fqdn" {
  value = one(azurerm_container_app.web[*].ingress[0].fqdn)
}

output "sast_job_name" {
  value = one(azurerm_container_app_job.sast[*].name)
}

output "migrate_job_name" {
  value = one(azurerm_container_app_job.migrate[*].name)
}

output "app_names" {
  value = compact([
    one(azurerm_container_app.web[*].name),
    one(azurerm_container_app.worker_admin[*].name),
    one(azurerm_container_app.beat[*].name),
    one(azurerm_container_app.worker_poc[*].name),
    azurerm_container_app.redis.name,
  ])
}
