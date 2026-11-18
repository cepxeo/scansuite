output "url" {
  description = "Where ScanSuite is served. Internal deployments serve on the Cloud Run URL, reachable only from inside the VPC / corporate network."
  value = (var.internal_only ? module.cloudrun.web_service_uri :
    (var.domain_name != "" ? "https://${var.domain_name}/" : "https://${one(module.lb[*].ip_address)}/")
  )
}

output "load_balancer_ip" {
  description = "Global anycast IP of the external HTTPS load balancer. Empty on internal-only deployments."
  value       = one(module.lb[*].ip_address)
}

output "scan_egress_ips" {
  description = "Static Cloud NAT addresses the workers egress from - repository clones and AI calls. Give these to anyone who allowlists by source IP. Empty with egress_mode = \"none\": the workers then reach internal hosts from the subnet range."
  value       = module.network.nat_ip_addresses
}

output "google_apis_range" {
  description = "With egress_mode = \"none\": the Private Google Access range googleapis.com and run.app resolve to inside the VPC. Route it from the corporate network to this VPC for internal browsers to reach the web UI."
  value       = module.network.google_apis_range
}

output "dns_inbound_forwarders_command" {
  description = "Lists the inbound DNS forwarder addresses the corporate DNS servers forward run.app to (dns_inbound_forwarding = true)."
  value       = var.dns_inbound_forwarding ? "gcloud compute addresses list --project ${var.project_id} --filter=purpose=DNS_RESOLVER --format=\"table(address,subnetwork)\"" : ""
}

output "cloud_run_services" {
  description = "The Cloud Run resources that make up the deployment."
  value = {
    web          = module.cloudrun.web_service_name
    sast_job     = module.cloudrun.sast_job_name
    pentest_job  = module.cloudrun.pentest_job_name
    migrate_job  = module.cloudrun.migrate_job_name
    worker_pools = module.cloudrun.worker_pool_names
  }
}

output "migrate_command" {
  description = "Run this after deploying a new image tag; it owns every schema change."
  value       = "gcloud run jobs execute ${module.cloudrun.migrate_job_name} --region ${var.region} --project ${var.project_id} --wait"
}

output "migrate_job_name" {
  description = "The Cloud Run migration job deploy.sh runs."
  value       = module.cloudrun.migrate_job_name
}

output "region" {
  value = var.region
}

output "image_repository" {
  description = "Where the images are read from, up to the image name. deploy.sh resolves their digests here."
  value       = local.image_repository
}

output "local_image_repository" {
  description = "The standard repository deploy.sh pushes local images to (LOCAL_IMAGES=1)."
  value       = module.artifact_registry.repository_url
}

output "images" {
  description = "The image references the workloads run."
  value = {
    web        = local.image_web
    worker     = local.image_worker
    worker_poc = local.image_worker_poc
    # The AI Pentest runner.
    worker_pentest = local.image_worker_pentest
  }
}

output "database_connection_name" {
  value = module.cloudsql.connection_name
}

output "database_private_ip" {
  value = module.cloudsql.private_ip
}

output "redis_host" {
  value = module.memorystore.host
}

output "artifact_bucket" {
  value = module.storage.artifact_bucket_name
}

output "artifact_registry_url" {
  description = "Push mirrored images here with scripts/mirror-images.sh, then set the image_* variables to match."
  value       = module.artifact_registry.repository_url
}

output "secret_names" {
  description = "Secret Manager entries holding the generated credentials."
  value       = module.secrets.secret_ids
}

output "project_id" {
  value = var.project_id
}
