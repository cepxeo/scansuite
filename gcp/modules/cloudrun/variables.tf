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
variable "image_poc_runner" {
  description = "The PoC runner image (ai-poc-runner): runner.py and the PoC libraries, no ScanSuite code."
  type        = string
}

variable "poc_subnet_name" {
  description = "The PoC runner job's subnet, whose egress rules close the installation's own ranges."
  type        = string
}

variable "poc_exchange_bucket" {
  description = "Bucket the broker hands each PoC's input and result through (signed URLs)."
  type        = string
}

variable "poc_task_timeout_seconds" {
  type    = number
  default = 600
}

variable "poc_max_runners" {
  description = "PoC runner executions of the installation at once."
  type        = number
  default     = 10
}

variable "config" {
  description = "Non-secret environment, shared by every workload. Includes PYARMOR_RKEY and PYARMOR_LICENSE_FILENAME."
  type        = map(string)
}

variable "secret_env" {
  description = "Environment variable name to Secret Manager secret id, for the full-trust workloads (web, workers, jobs). Includes the licence and LLM key blobs."
  type        = map(string)
}

variable "admin_instances" {
  description = "Instances consuming the admin queue. One is enough: these tasks are short orchestration steps."
  type        = number
  default     = 1
}

variable "admin_memory" {
  description = "Memory of each admin worker instance; it loads the exploitable-CVE feed (see the root variable)."
  type        = string
  default     = "4Gi"
}

variable "poc_instances" {
  description = "Instances of the PoC broker on the poc queue (it runs no PoC)."
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


variable "image_worker_pentest" {
  description = "AI Pentest runner image (ai-worker-pentest)."
  type        = string
}

variable "pentest_cpu" {
  type    = string
  default = "4"
}

variable "pentest_memory" {
  description = "The writable filesystem (scanner output) is in memory and counts against this."
  type        = string
  default     = "16Gi"
}

variable "pentest_task_timeout_seconds" {
  type    = number
  default = 86400
}

variable "pentest_max_runners" {
  description = "AI Pentest runners (pentest job tasks) of the installation at once."
  type        = number
  default     = 20
}
