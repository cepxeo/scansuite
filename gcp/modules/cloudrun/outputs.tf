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

output "pentest_job_name" {
  value = google_cloud_run_v2_job.pentest.name
}

output "poc_job" {
  description = "What the PoC runner job runs with, for the tests: its identity, environment, network and image."
  value = {
    name            = google_cloud_run_v2_job.poc.name
    service_account = google_cloud_run_v2_job.poc.template[0].template[0].service_account
    env_names       = [for env in google_cloud_run_v2_job.poc.template[0].template[0].containers[0].env : env.name]
    subnetwork      = google_cloud_run_v2_job.poc.template[0].template[0].vpc_access[0].network_interfaces[0].subnetwork
    tags            = google_cloud_run_v2_job.poc.template[0].template[0].vpc_access[0].network_interfaces[0].tags
    image           = google_cloud_run_v2_job.poc.template[0].template[0].containers[0].image
  }
}

output "poc_broker_service_account" {
  value = google_cloud_run_v2_worker_pool.poc.template[0].service_account
}
