output "url" {
  description = "Where ScanSuite is served. Internal deployments serve on the Cloud Run URL, reachable only from inside the VPC / corporate network."
  value = (var.internal_only ?
    (local.use_cloudrun ? one(module.cloudrun[*].web_service_uri) : "internal (GKE) - front with an internal LoadBalancer Service") :
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

output "platform" {
  value = var.platform
}

output "cluster_name" {
  description = "Empty on Cloud Run - there is no cluster."
  value       = one(module.gke[*].cluster_name)
}

output "kubectl_credentials_command" {
  value = local.use_gke ? "gcloud container clusters get-credentials ${one(module.gke[*].cluster_name)} --region ${var.region} --project ${var.project_id}" : "not applicable - platform is cloudrun"
}

output "cloud_run_services" {
  description = "The Cloud Run resources that make up the deployment."
  value = local.use_cloudrun ? {
    web          = one(module.cloudrun[*].web_service_name)
    sast_job     = one(module.cloudrun[*].sast_job_name)
    migrate_job  = one(module.cloudrun[*].migrate_job_name)
    worker_pools = one(module.cloudrun[*].worker_pool_names)
  } : null
}

output "migrate_command" {
  description = "Run this after deploying a new image tag; it owns every schema change."
  value       = local.use_cloudrun ? "gcloud run jobs execute ${one(module.cloudrun[*].migrate_job_name)} --region ${var.region} --project ${var.project_id} --wait" : "kubectl -n scansuite run migrate --rm -it --image=${local.image_worker} --command -- python /app/migrate.py"
}

output "migrate_job_name" {
  description = "The Cloud Run migration job deploy.sh runs. Empty on GKE, where an init container migrates."
  value       = local.use_cloudrun ? one(module.cloudrun[*].migrate_job_name) : ""
}

output "region" {
  value = var.region
}

output "image_repository" {
  description = "Where the three images are read from, up to the image name. deploy.sh resolves their digests here."
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
