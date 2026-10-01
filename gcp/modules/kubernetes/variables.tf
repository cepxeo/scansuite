variable "prefix" { type = string }
variable "namespace" { type = string }
variable "project_id" { type = string }

variable "app_service_account_email" { type = string }
variable "poc_service_account_email" { type = string }

variable "image_web" { type = string }
variable "image_worker" { type = string }
variable "image_worker_poc" { type = string }

variable "dockerhub_username" { type = string }
variable "dockerhub_token" {
  type      = string
  sensitive = true
}

variable "db_host" { type = string }
variable "db_name" { type = string }
variable "db_user" { type = string }
variable "db_password" {
  type      = string
  sensitive = true
}

variable "team_wrapping_keys" {
  description = "SCANSUITE_WRAPPING_KEYS: team secret wrapping keys (JSON of key id to base64 key)."
  type        = string
  sensitive   = true
}


variable "redis_host" { type = string }
variable "redis_password" {
  type      = string
  sensitive = true
}

variable "artifact_bucket" { type = string }

variable "flask_secret_key" {
  type      = string
  sensitive = true
}

variable "pyarmor_license_b64" {
  description = "Base64 of the PyArmor outer licence, decoded into /key at container start."
  type        = string
  sensitive   = true
}

variable "pyarmor_licence_filename" {
  description = "Filename the decoded licence must have inside /key."
  type        = string
}

variable "llm_sa_key_b64" {
  description = "Base64 of the llm-scansuit key JSON, decoded to /key/key.json. Empty leaves the app without GCP credentials until supplied."
  type        = string
  default     = ""
  sensitive   = true
}

variable "timezone" { type = string }
variable "enable_static_scans" { type = string }
variable "enable_dynamic_scans" { type = string }

variable "worker_replicas" { type = number }
variable "poc_replicas" { type = number }
variable "scratch_disk_gb" { type = number }

variable "probe_source_cidrs" {
  description = "Ranges allowed to reach pods past the default-deny ingress policy: node and pod ranges for kubelet probes."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "lb_source_cidrs" {
  description = "Google Front End ranges. Both health checks and real client traffic arrive from these."
  type        = list(string)
  default     = ["130.211.0.0/22", "35.191.0.0/16"]
}

variable "image_pull_registry" {
  description = "Registry host for the pull secret auths entry (Docker Hub by default; quay.apps.cloud.internal for internal Quay)."
  type        = string
  default     = "https://index.docker.io/v1/"
}

variable "redis_config" {
  description = "REDIS_PORT, REDIS_TLS, REDIS_CA_PEM and REDIS_CA_CERTS, merged into the shared configuration."
  type        = map(string)
  default     = {}
}
