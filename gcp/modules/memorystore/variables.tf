variable "project_id" { type = string }
variable "region" { type = string }
variable "primary_zone" { type = string }
variable "prefix" { type = string }
variable "labels" { type = map(string) }
variable "network_id" { type = string }
variable "memory_gb" { type = number }
variable "highly_available" { type = bool }

variable "tls" {
  description = "Encrypt client traffic (SERVER_AUTHENTICATION, port 6378). Changing it replaces the instance."
  type        = bool
  default     = true
}
