###############################################################################
# Platform
###############################################################################

variable "platform" {
  description = <<-EOT
    Where the application runs.

    cloudrun (default)
      A Cloud Run service for the web UI, worker pools for the admin, beat and
      PoC queues, and one job execution per scan. No cluster to operate, and
      worker pools bill for resources rather than requests. Scans are dispatched
      by the application through EXECUTION_BACKEND=cloudrun.

    gke
      The regional GKE Standard cluster: web, worker-admin and celery-beat as
      Deployments, the scan worker as a StatefulSet consuming the Celery queue,
      and worker-poc on a gVisor node pool. Choose this when you want a
      configurable termination grace period - Cloud Run allows ten seconds and
      no more - or node-level control over the scan workers.

    Both run the same images. The difference is the execution backend and who
    runs the migration job: a Cloud Run job, or an init container of the web
    Deployment on GKE. Application processes never change the schema.
  EOT
  type        = string
  default     = "cloudrun"

  validation {
    condition     = contains(["cloudrun", "gke"], var.platform)
    error_message = "platform must be \"cloudrun\" or \"gke\"."
  }
}

###############################################################################
# Project / location
###############################################################################

variable "project_id" {
  description = "Existing GCP project id to deploy into."
  type        = string
}

variable "region" {
  description = "GCP region. Frankfurt is the default; europe-west4 (Netherlands) is the closest alternative."
  type        = string
  default     = "europe-west3"
}

variable "zones" {
  description = <<-EOT
    Zones the general node pool spans. All three must carry at least one node:
    the load balancer is wired to standalone zonal NEGs, and a NEG only exists
    in a zone where the cluster has nodes.
  EOT
  type        = list(string)
  default     = ["europe-west3-a", "europe-west3-b", "europe-west3-c"]
}

variable "primary_zone" {
  description = "Zone that hosts the scan engine and the PoC sandbox. Its persistent disks are zonal, so this pins them."
  type        = string
  default     = "europe-west3-b"
}

variable "name_prefix" {
  description = "Prefix for every resource name."
  type        = string
  default     = "scansuite"
}

variable "environment" {
  description = "Environment label (dev / stage / prod). Drives resource labels and a few sizing defaults."
  type        = string
  default     = "prod"
}

###############################################################################
# Access / safety
###############################################################################

variable "master_authorized_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the GKE control plane. Leave null to auto-detect the
    IP address Terraform is running from and allow only that /32 — which is what
    makes a first apply work from a laptop without any manual configuration. Set
    it explicitly for CI (for example the NAT egress range of your runners).
  EOT
  type        = list(string)
  default     = null
}

variable "deletion_protection" {
  description = "Protect the GKE cluster and the Cloud SQL instance from deletion. Set true for prod; false lets `terraform destroy` work."
  type        = bool
  default     = false
}

variable "enable_secrets_encryption" {
  description = "Encrypt Kubernetes Secrets in etcd with a Cloud KMS key (application-layer CMEK) on top of Google's default at-rest encryption."
  type        = bool
  default     = false
}

###############################################################################
# Networking
###############################################################################

variable "subnet_cidr" {
  description = "Primary node subnet."
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary range for pods."
  type        = string
  default     = "10.20.0.0/14"
}

variable "services_cidr" {
  description = "Secondary range for services."
  type        = string
  default     = "10.24.0.0/20"
}

variable "master_cidr" {
  description = "/28 for the private GKE control plane."
  type        = string
  default     = "172.16.0.0/28"
}

variable "nat_ip_count" {
  description = "Reserved static egress IPs. These are the addresses scans originate from, so customers allowlist them - keep them stable."
  type        = number
  default     = 2
}

###############################################################################
# Node pools
###############################################################################

variable "general_machine_type" {
  description = "Machine type for the general pool (web, celery-beat)."
  type        = string
  default     = "e2-standard-2"
}

variable "scan_engine_machine_type" {
  description = "Machine type for the scan engine. AI static analysis is dominated by waiting on model calls, with bursts of git clone, Trivy and secret scanning - all of which run natively inside the worker image."
  type        = string
  default     = "n2-standard-4"
}

variable "worker_replicas" {
  description = <<-EOT
    Scan workers. Each gets its own scratch volume, and with no shared Docker
    daemon there is nothing left for replicas to contend over: the schema is
    changed only by the migrate job. Note that worker_concurrency = 1 with
    pool = solo means one replica is one concurrent scan.
  EOT
  type        = number
  default     = 1
}

variable "poc_machine_type" {
  description = "Machine type for the gVisor-sandboxed PoC pool."
  type        = string
  default     = "e2-standard-2"
}

variable "poc_replicas" {
  description = "Replicas of worker-poc. This is the only workload that is safe to scale horizontally today - see README section 'What still blocks autoscaling'."
  type        = number
  default     = 2
}

###############################################################################
# Data services
###############################################################################

variable "cloudsql_name" {
  description = "Cloud SQL instance name. Empty keeps <name_prefix>-pg. A deleted instance's name cannot be reused for about a week: set another one to redeploy sooner."
  type        = string
  default     = ""
}

variable "cloudsql_tier" {
  description = "Cloud SQL machine tier."
  type        = string
  default     = "db-custom-2-8192"
}

variable "cloudsql_disk_gb" {
  description = "Cloud SQL data disk size in GB (autoresize is on)."
  type        = number
  default     = 100
}

variable "cloudsql_ha" {
  description = "Regional (HA) Cloud SQL. Set false in dev to roughly halve the bill."
  type        = bool
  default     = true
}

variable "redis_memory_gb" {
  description = "Memorystore capacity in GB."
  type        = number
  default     = 4
}

variable "redis_ha" {
  description = "STANDARD_HA (replica + automatic failover) versus BASIC."
  type        = bool
  default     = true
}

variable "redis_tls" {
  description = "Encrypt traffic to Memorystore (SERVER_AUTHENTICATION on port 6378, verified against the instance's CA). Turning it on or off replaces the instance: anything queued at that moment is lost, so change it when no scan is running."
  type        = bool
  default     = true
}

###############################################################################
# Application images
###############################################################################

variable "image_tag" {
  description = "Tag of teams-web, teams-worker and teams-worker-poc: your licence code, the <code> of key/<name>_<code>.lic. The licence opens only the images of its own code. Required unless all three image_* overrides are set."
  type        = string
  default     = ""
}

variable "image_source" {
  description = "Docker Hub namespace the images come from. The deployment pulls them through an Artifact Registry remote repository in front of Docker Hub, never from Docker Hub directly: Cloud Run cannot pull private Docker Hub images."
  type        = string
  default     = "appsec4u"
}

variable "image_repository" {
  description = "Where the three images are read from, up to the image name (e.g. europe-west3-docker.pkg.dev/<project>/scansuite). Empty uses the remote repository in front of Docker Hub. deploy.sh sets it when it pushes local images (LOCAL_IMAGES=1)."
  type        = string
  default     = ""
}

variable "image_digests" {
  description = "teams-web / teams-worker / teams-worker-poc -> sha256 digest. deploy.sh writes these (images.auto.tfvars.json) so a rebuild under the same tag still rolls every workload to the new image; without a digest the tag is used."
  type        = map(string)
  default     = {}
}

variable "image_web" {
  description = "Full web image reference, used verbatim instead of the derived one (an internal registry, for example). Empty derives it from image_repository/image_tag."
  type        = string
  default     = ""
}

variable "image_worker" {
  description = "Full worker image reference (also runs worker-admin, celery-beat, the scan and migrate jobs), used verbatim. Empty derives it."
  type        = string
  default     = ""
}

variable "image_worker_poc" {
  description = "Full PoC executor image reference, used verbatim. Empty derives it; it is built per release like the others, under the same tag."
  type        = string
  default     = ""
}

variable "dockerhub_username" {
  description = "Docker Hub user the remote repository (and, on GKE with image overrides, the pull secret) authenticates as. The appsec4u repositories are private: use the user and token sent with your licence."
  type        = string
  default     = ""
}

variable "dockerhub_token" {
  description = "Docker Hub access token for dockerhub_username. Kept in Secret Manager, readable only by the Artifact Registry service agent."
  type        = string
  default     = ""
  sensitive   = true
}

###############################################################################
# Application configuration
###############################################################################

variable "key_dir" {
  description = <<-EOT
    Local directory whose files are mounted at /key inside the web and worker
    containers. It must contain the PyArmor outer licence (<name>_<tag>.lic)
    that matches the image tag - the obfuscated code will not start without it.
    Defaults to the repository's own key/ directory. key.json is ignored here:
    Terraform generates a fresh service-account key for the deployment.
  EOT
  type        = string
  default     = ""
}

variable "web_allowed_cidrs" {
  description = "Source ranges (CIDR) allowed to reach the web UI through the external load balancer, such as your office or VPN. Empty allows the whole internet. Set it before the first deploy: a new installation's setup page belongs to whoever opens it first. At most 10 ranges (one Cloud Armor rule). Ignored with internal_only."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.web_allowed_cidrs) <= 10
    error_message = "web_allowed_cidrs takes at most 10 ranges."
  }
}

variable "domain_name" {
  description = "Public hostname. Leave empty to serve on the load balancer IP with a self-signed certificate (works immediately, browser warning); set it to get a Google-managed certificate."
  type        = string
  default     = ""
}

variable "manage_dns" {
  description = "Create a Cloud DNS zone and an A record for domain_name. You still have to delegate the zone at your registrar - that part cannot be automated."
  type        = bool
  default     = false
}

variable "timezone" {
  description = "TZ for the containers. celery_beat reads it when building the schedule."
  type        = string
  default     = "Europe/Moscow"
}

variable "enable_static_scans" {
  type    = string
  default = "True"
}

variable "enable_dynamic_scans" {
  description = "Off by default. Dynamic and infrastructure scanning launch scanner containers through a Docker daemon, and this deployment has none - see README, 'Static analysis only'."
  type        = string
  default     = "False"
}

###############################################################################
# Storage sizing
###############################################################################

variable "scratch_disk_gb" {
  description = "Scan scratch space at /var/tmp, per worker replica - repository clones under /var/tmp/scansuite/sast/<scan_id>, git credential helpers, and intermediate analysis output before it is uploaded to Cloud Storage."
  type        = number
  default     = 200
}

variable "artifact_retention_days" {
  description = "Days before noncurrent artifact versions are deleted from the bucket."
  type        = number
  default     = 30
}

variable "artifact_bucket_force_destroy" {
  description = "Let terraform destroy delete the artifact bucket with the scan artifacts in it. Off keeps them; destroy.sh --delete-artifacts turns it on just before destroying."
  type        = bool
  default     = false
}

###############################################################################
# Observability
###############################################################################

variable "alert_email" {
  description = "Email address for alert notifications. Leave empty to create the alert policies without a channel."
  type        = string
  default     = ""
}

###############################################################################
# Cloud Run sizing (platform = cloudrun)
###############################################################################

variable "scan_cpu" {
  description = "vCPU for one scan job execution. Cloud Run allows up to 8."
  type        = string
  default     = "4"
}

variable "scan_memory" {
  description = "Memory for one scan job execution. The writable filesystem is in memory and counts against this, so it has to cover the repository clone as well as the process. Cloud Run allows up to 32Gi."
  type        = string
  default     = "16Gi"
}

variable "scan_task_timeout_seconds" {
  description = "Ceiling for one scan job execution. Cloud Run allows up to 168h; the default matches the Celery task_time_limit of 48h."
  type        = number
  default     = 172800
}

variable "web_min_instances" {
  description = "Warm web instances. One avoids a cold start on the first request of the day; zero is cheaper."
  type        = number
  default     = 1
}

variable "web_max_instances" {
  type    = number
  default = 4
}

variable "admin_instances" {
  description = "Instances consuming the admin queue."
  type        = number
  default     = 1
}

###############################################################################
# LLM / key injection
###############################################################################

variable "llm_service_account_email" {
  description = "Existing service account (e.g. llm-scansuit@<project>.iam.gserviceaccount.com) the app authenticates as for Cloud Storage and Vertex AI, via the injected /key/key.json. Empty skips the bucket/Vertex role grants."
  type        = string
  default     = ""
}

variable "llm_sa_key_b64" {
  description = "Base64 of the llm-scansuit key JSON, injected as a secret and decoded to /key/key.json at container start. Leave empty to create the secret container only and add the version out of band (gcloud secrets versions add) - keeps the key out of Terraform state."
  type        = string
  default     = ""
  sensitive   = true
}

variable "pyarmor_license_file" {
  description = "Exact PyArmor licence filename inside key_dir, e.g. commerzbank-ag_be1784.lic. Must match the deployed image tag. Leave empty only when key_dir holds exactly one .lic."
  type        = string
  default     = ""
}

variable "llm_sa_key_file" {
  description = "Path (relative to infra/) to the llm-scansuite key JSON. Terraform base64-encodes it and injects it as the /key/key.json secret. Preferred over pasting base64 into llm_sa_key_b64."
  type        = string
  default     = ""
}

variable "image_pull_registry" {
  description = "Registry host the image pull secret authenticates to. Default is Docker Hub; set to quay.apps.cloud.internal for the internal Quay. Credentials come from dockerhub_username/dockerhub_token (a Quay robot account here)."
  type        = string
  default     = "https://index.docker.io/v1/"
}

variable "internal_only" {
  description = <<-EOT
    No public/external exposure. On Cloud Run the web service gets
    INGRESS_TRAFFIC_INTERNAL_ONLY and the external Application Load Balancer is
    not created - the UI is reached over the VPC / corporate network via the
    Cloud Run URL (HTTPS on *.run.app, served only to internal callers through
    the restricted Google APIs path). The uptime check is skipped because
    Google's probers cannot reach an internal endpoint.

    (GKE internal exposure is not wired by this flag - the web Service would need
    to become an internal LoadBalancer; use Cloud Run for the internal-only
    deployment.)
  EOT
  type        = bool
  default     = false
}

###############################################################################
# Platform console (optional, off by default)
###############################################################################
