variable "project_id" { type = string }
variable "region" { type = string }
variable "prefix" { type = string }
variable "labels" { type = map(string) }

variable "network_name" { type = string }
variable "subnet_name" { type = string }

variable "app_service_account_email" { type = string }
variable "poc_service_account_email" { type = string }
variable "migrate_service_account_email" {
  description = "Identity of the migrate job; the only one that can read the schema owner's password."
  type        = string
}

variable "image_web" { type = string }
variable "image_worker" { type = string }
variable "image_worker_poc" { type = string }

variable "config" {
  description = "Non-secret environment, shared by every workload. Includes PYARMOR_RKEY and PYARMOR_LICENSE_FILENAME."
  type        = map(string)
}

variable "secret_env" {
  description = "Environment variable name to Secret Manager secret id, for the full-trust workloads (web, workers, jobs). Includes the licence and LLM key blobs."
  type        = map(string)
}

variable "secret_env_poc" {
  description = "Reduced secret env for worker-poc, which runs model-written code: database and broker only, never the licence or LLM key."
  type        = map(string)
}

variable "admin_instances" {
  description = "Instances consuming the admin queue. One is enough: these tasks are short orchestration steps."
  type        = number
  default     = 1
}

variable "poc_instances" {
  description = "Instances consuming the poc queue."
  type        = number
  default     = 1
}

variable "web_min_instances" {
  description = "Keeping one warm avoids paying the Flask start on the first request of the day."
  type        = number
  default     = 1
}

variable "web_max_instances" {
  type    = number
  default = 4
}

variable "scan_task_timeout_seconds" {
  description = "Ceiling for one scan job execution. Cloud Run allows up to 168h; this matches the Celery task_time_limit of 48h."
  type        = number
  default     = 172800
}

variable "scan_cpu" {
  type    = string
  default = "4"
}

variable "scan_memory" {
  description = "The writable filesystem is in memory and counts against this, so it has to cover the repository clone as well as the process."
  type        = string
  default     = "16Gi"
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "internal_only" {
  description = "Internal ingress only (no external LB). The web service is reachable from within the VPC / corporate network via its run.app URL."
  type        = bool
  default     = false
}

