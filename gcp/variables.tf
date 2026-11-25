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

variable "primary_zone" {
  description = "Zone of the Memorystore primary."
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

variable "deletion_protection" {
  description = "Protect the Cloud SQL instance and the Cloud Run jobs and services from deletion. Set true for prod; false lets `terraform destroy` work."
  type        = bool
  default     = false
}

###############################################################################
# Networking
###############################################################################

variable "subnet_cidr" {
  description = "The subnet the Cloud Run workloads egress through (Direct VPC egress)."
  type        = string
  default     = "10.10.0.0/20"
}

variable "nat_ip_count" {
  description = "Reserved static egress IPs (egress_mode = \"nat\"). These are the addresses scans originate from, so customers allowlist them - keep them stable."
  type        = number
  default     = 2
}

variable "egress_mode" {
  description = <<-EOT
    How the workloads reach anything outside the VPC.
      "nat"  - Cloud NAT on nat_ip_count reserved external addresses (default).
      "none" - no external address anywhere: no NAT and no default internet
               route. Google APIs (Vertex AI, Cloud Storage, the Cloud Run API)
               go through Private Google Access on google_apis_vip, with
               private DNS zones for googleapis.com and run.app. Everything
               else - internal Git hosts - must be reachable over the corporate
               connection attached to this VPC, its names resolved through
               dns_forwarding_zones.
  EOT
  type        = string
  default     = "nat"

  validation {
    condition     = contains(["nat", "none"], var.egress_mode)
    error_message = "egress_mode is \"nat\" or \"none\"."
  }
}

variable "google_apis_vip" {
  description = "With egress_mode = \"none\": the Private Google Access range. \"private\" (199.36.153.8/30) serves every Google API; \"restricted\" (199.36.153.4/30) only those VPC Service Controls supports - use it when the project is inside a perimeter."
  type        = string
  default     = "private"

  validation {
    condition     = contains(["private", "restricted"], var.google_apis_vip)
    error_message = "google_apis_vip is \"private\" or \"restricted\"."
  }
}

variable "psa_cidr" {
  description = "Range reserved for Cloud SQL and Memorystore (private services access), at least a /24; a /16 leaves room for more instances. Take it from the corporate address plan when the VPC is connected to the corporate network."
  type        = string
  default     = "10.30.0.0/16"
}

variable "dns_forwarding_zones" {
  description = "Internal domains the workloads must resolve (Git hosts, for example), each forwarded to the corporate DNS servers over the corporate connection: { \"corp.example.\" = [\"10.0.0.53\", \"10.0.1.53\"] }."
  type        = map(list(string))
  default     = {}
}

variable "dns_inbound_forwarding" {
  description = "Create inbound DNS forwarders in the subnet. The corporate DNS servers forward run.app to them, so internal browsers resolve the web UI's Cloud Run URL to the Google APIs range (egress_mode = \"none\")."
  type        = bool
  default     = false
}

###############################################################################
# PoC workers
###############################################################################

variable "poc_replicas" {
  description = "Instances of the worker-poc pool: the PoC broker on the poc queue. It runs no PoC; each one is an execution of the poc job."
  type        = number
  default     = 1
}

variable "poc_max_runners" {
  description = "PoC runner executions of the whole installation at once; further PoCs wait for a free one."
  type        = number
  default     = 10
}

variable "poc_task_timeout_seconds" {
  description = "Ceiling for one PoC runner execution: the longest PoC timeout (300 s), its start and the result upload."
  type        = number
  default     = 600
}

variable "poc_subnet_cidr" {
  description = "Subnet of the PoC runner job (Direct VPC egress, a /26 or larger). It must not overlap subnet_cidr or psa_cidr."
  type        = string
  default     = "10.20.8.0/26"
}

variable "poc_denied_ranges" {
  description = "Further ranges the PoC runner may not reach (it never reaches subnet_cidr or psa_cidr), e.g. corporate management networks."
  type        = list(string)
  default     = []
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
  description = "Tag of ai-web, ai-worker, ai-poc-runner and ai-worker-pentest: your licence code, the <code> of key/<name>_<code>.lic. The licence opens only the images of its own code. Required unless the image_* overrides are set."
  type        = string
  default     = ""
}

variable "image_source" {
  description = "Docker Hub namespace the images come from. The deployment pulls them through an Artifact Registry remote repository in front of Docker Hub, never from Docker Hub directly: Cloud Run cannot pull private Docker Hub images."
  type        = string
  default     = "appsec4u"
}

variable "image_repository" {
  description = "Where the images are read from, up to the image name (e.g. europe-west3-docker.pkg.dev/<project>/scansuite). Empty uses the remote repository in front of Docker Hub. deploy.sh sets it when it pushes local images (LOCAL_IMAGES=1)."
  type        = string
  default     = ""
}

variable "image_digests" {
  description = "ai-web / ai-worker / ai-poc-runner / ai-worker-pentest -> sha256 digest. deploy.sh writes these (images.auto.tfvars.json) so a rebuild under the same tag still rolls every workload to the new image; without a digest the tag is used."
  type        = map(string)
  default     = {}
}

variable "source_registry" {
  description = <<-EOT
    A registry to copy the images from, up to the image name - for example an
    internal Quay organisation, "quay.example.internal/scansuite". Cloud Run
    cannot pull from a private registry outside Google Cloud, so deploy.sh
    signs in with SOURCE_REGISTRY_USERNAME and SOURCE_REGISTRY_TOKEN (taken from
    the environment, never stored), copies <name>:<image_tag> of each image
    into the project's own Artifact Registry repository and deploys that copy
    by digest. Empty reads the images from Docker Hub through the remote
    repository instead, which is then not created.
  EOT
  type        = string
  default     = ""
}

variable "source_image_names" {
  description = "Image names in source_registry, when they differ from the canonical ones (ai-web, ai-worker, ai-poc-runner, ai-worker-pentest). The copies keep the canonical names. A name left out is looked up as its canonical one."
  type        = map(string)
  default = {
    ai-web            = "ai-web"
    ai-worker         = "ai-worker"
    ai-poc-runner     = "ai-poc-runner"
    ai-worker-pentest = "ai-worker-pentest"
  }

  # Any subset: a name left out is its canonical one, and an entry for an image
  # that no longer exists (ai-worker-poc, before 2026-11-25) is ignored, so a
  # terraform.tfvars written for an earlier release needs no change.
  validation {
    condition     = alltrue([for name in values(var.source_image_names) : trimspace(name) != ""])
    error_message = "source_image_names values must not be empty."
  }
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

variable "image_poc_runner" {
  description = "Full PoC runner image reference, used verbatim. Empty derives it (ai-poc-runner, same tag as the others)."
  type        = string
  default     = ""
}

variable "image_worker_poc" {
  description = "Before 2026-11-25: the PoC executor image, which ai-poc-runner replaces. Still read so that an earlier terraform.tfvars needs no change: a tag reference (.../ai-worker-poc:<tag>) gives image_poc_runner the same repository and tag under the new name. Prefer image_poc_runner."
  type        = string
  default     = ""

  validation {
    condition     = !strcontains(var.image_worker_poc, "@")
    error_message = "image_worker_poc is pinned by digest, which cannot name the PoC runner image that replaces it: set image_poc_runner (\".../ai-poc-runner@sha256:...\" or \":<tag>\") instead."
  }
}

variable "dockerhub_username" {
  description = "Docker Hub user the remote repository authenticates as. The appsec4u repositories are private: use the user and token sent with your licence."
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

###############################################################################
# Storage sizing
###############################################################################

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
# Cloud Run sizing
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

variable "admin_memory" {
  description = "Memory of each admin worker instance (one CPU allows up to 4Gi). The exploitable-CVE feed load (worker/parsers/vulndb.py) needs about 1Gi with the 2026-11 feed; at 2Gi the 2026-11 build, which parsed the feed whole, was killed mid-load and left the vulns table empty."
  type        = string
  default     = "4Gi"
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
  description = "Exact PyArmor licence filename inside key_dir, e.g. acme-gmbh_a1b2c3.lic. Must match the deployed image tag. Leave empty only when key_dir holds exactly one .lic."
  type        = string
  default     = ""
}

variable "llm_sa_key_file" {
  description = "Path (relative to infra/) to the llm-scansuite key JSON. Terraform base64-encodes it and injects it as the /key/key.json secret. Preferred over pasting base64 into llm_sa_key_b64."
  type        = string
  default     = ""
}

variable "internal_only" {
  description = <<-EOT
    No public/external exposure. The web service gets
    INGRESS_TRAFFIC_INTERNAL_ONLY and the external Application Load Balancer is
    not created - the UI is reached over the VPC / corporate network via the
    Cloud Run URL (HTTPS on *.run.app, served only to internal callers through
    the restricted Google APIs path). The uptime check is skipped because
    Google's probers cannot reach an internal endpoint.
  EOT
  type        = bool
  default     = false
}

###############################################################################
# AI Pentest runner (docs: AI Pentest scaling architecture, 3.5)
###############################################################################

variable "image_worker_pentest" {
  description = "Full AI Pentest runner image reference, used verbatim. Empty derives it (ai-worker-pentest, same tag as the others)."
  type        = string
  default     = ""
}

variable "pentest_cpu" {
  description = "vCPU for one AI Pentest runner (a lead and up to four sub-agents with their scanners). Cloud Run allows up to 8."
  type        = string
  default     = "4"
}

variable "pentest_memory" {
  description = "Memory for one AI Pentest runner. The writable filesystem (scanner output) is in memory and counts against this. Cloud Run allows up to 32Gi."
  type        = string
  default     = "16Gi"
}

variable "pentest_task_timeout_seconds" {
  description = "Ceiling for one AI Pentest runner. An engagement is 3 h by default and up to about 12 h for large host scopes; Cloud Run allows up to 168h."
  type        = number
  default     = 86400
}

variable "extra_env" {
  description = <<-EOT
    More environment variables for every ScanSuite service and job on Cloud Run
    (web, workers, the scan and AI Pentest jobs): settings that have no
    Terraform variable of their own, such as the AI Pentest's sharding
    (AI_PENTEST_RUNNERS_PER_SCAN, AI_PENTEST_SINGLE_SHARD_ORIGINS,
    AI_PENTEST_SINGLE_SHARD_ADDRESSES, AI_PENTEST_HOSTS_PER_SHARD, ...; the
    AI Pentest safeguards and run budgets are System settings), the largest upload
    (MAX_UPLOAD_MB, default 2000), Anthropic prompt caching
    (SCANSUITE_PROMPT_CACHE=0 turns it off; SCANSUITE_PROMPT_CACHE_LONG_TTL, 1h
    or 5m) and the exploitable-CVE feed between releases, all off unless set
    (VULNDB_FEED_URL with VULNDB_FEED_PUBLIC_KEY pulls a signed feed,
    VULNDB_FAST_LANE=1 lists CISA KEV and SSVC "active" CVEs hourly). Plain
    values, visible in the service configuration: never a secret. A name the
    deployment sets itself (PS_DATABASE_PORT among them) is refused; the
    deployment has one database account, so PS_MIGRATION_* are not used here.
    Changing it rolls the services to a new revision.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for name in keys(var.extra_env) : can(regex("^[A-Z][A-Z0-9_]*$", name))])
    error_message = "extra_env: names are upper case letters, digits and underscores, starting with a letter."
  }
}

variable "pentest_max_runners" {
  description = "AI Pentest runners of the whole installation at once: one runner is one task of the pentest job, with pentest_cpu and pentest_memory. A sharded scan uses up to AI_PENTEST_RUNNERS_PER_SCAN of them (default 4); scans beyond the cap wait for a free runner."
  type        = number
  default     = 20
}

variable "pentest_safeguard_floor" {
  description = "A preset the AI Pentest safeguards cannot go below (AI_PENTEST_SAFEGUARD_FLOOR): standard or production. The safeguards themselves are System settings (Security -> AI Pentest safeguards); with production, no administrator can loosen them past the production profile, and a run needs a run window and a contact before it starts. Empty: no floor."
  type        = string
  default     = ""

  validation {
    condition     = contains(["", "standard", "production"], var.pentest_safeguard_floor)
    error_message = "pentest_safeguard_floor is \"\", \"standard\" or \"production\"."
  }
}
