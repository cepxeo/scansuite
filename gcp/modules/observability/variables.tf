variable "project_id" { type = string }
variable "prefix" { type = string }
variable "alert_email" { type = string }
variable "lb_ip" { type = string }
variable "domain_name" { type = string }
variable "cloudsql_instance" { type = string }

variable "platform" {
  description = "cloudrun or gke - decides which resource types the log filters and alerts target."
  type        = string
  default     = "cloudrun"
}

variable "internal_only" {
  description = "When true, skip the uptime check - Google's probers cannot reach an internal endpoint."
  type        = bool
  default     = false
}

variable "uptime_token" {
  description = "Sent by the uptime check in the X-ScanSuite-Uptime header, which Cloud Armor lets through ahead of web_allowed_cidrs."
  type        = string
  sensitive   = true
}
