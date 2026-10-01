output "web_service_name" {
  value = google_cloud_run_v2_service.web.name
}

output "web_service_uri" {
  description = "The service's own URL. Ingress is restricted to the load balancer, so this is for reference, not for browsing to."
  value       = google_cloud_run_v2_service.web.uri
}

output "sast_job_name" {
  value = google_cloud_run_v2_job.sast.name
}

output "migrate_job_name" {
  value = google_cloud_run_v2_job.migrate.name
}

output "worker_pool_names" {
  value = [
    google_cloud_run_v2_worker_pool.admin.name,
    google_cloud_run_v2_worker_pool.beat.name,
    google_cloud_run_v2_worker_pool.poc.name,
  ]
}
