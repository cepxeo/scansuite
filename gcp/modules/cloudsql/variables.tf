variable "project_id" { type = string }
variable "region" { type = string }
variable "prefix" { type = string }
variable "labels" { type = map(string) }
variable "network_id" { type = string }
variable "tier" { type = string }
variable "disk_gb" { type = number }
variable "highly_available" { type = bool }
variable "deletion_protection" { type = bool }

variable "db_password" {
  type      = string
  sensitive = true
}

variable "name" {
  description = "Instance name. Empty keeps <prefix>-pg."
  type        = string
  default     = ""
}
