variable "project_id" { type = string }
variable "region" { type = string }
variable "zones" { type = list(string) }
variable "prefix" { type = string }
variable "web_neg_name" {
  description = "Zonal NEG name created by GKE. Unused when backend_mode is cloudrun."
  type        = string
  default     = ""
}
variable "domain_name" { type = string }
variable "manage_dns" { type = bool }

variable "backend_mode" {
  description = "Which kind of backend the load balancer fronts: \"cloudrun\" (serverless NEG) or \"gke\" (zonal NEGs)."
  type        = string

  validation {
    condition     = contains(["cloudrun", "gke"], var.backend_mode)
    error_message = "backend_mode must be cloudrun or gke."
  }
}

variable "cloud_run_service" {
  description = "Cloud Run service name for the serverless NEG. Unused when backend_mode is gke."
  type        = string
  default     = ""
}

variable "web_allowed_cidrs" {
  description = "Source ranges allowed through the load balancer. Empty allows everyone."
  type        = list(string)
  default     = []
}

variable "uptime_token" {
  description = "Requests carrying it in X-ScanSuite-Uptime (the uptime check) pass ahead of web_allowed_cidrs."
  type        = string
  sensitive   = true
}
