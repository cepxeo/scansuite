variable "project_id" { type = string }
variable "region" { type = string }
variable "prefix" { type = string }
variable "domain_name" { type = string }
variable "manage_dns" { type = bool }

variable "cloud_run_service" {
  description = "Cloud Run web service name for the serverless NEG."
  type        = string
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
