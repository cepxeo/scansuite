variable "project_id" { type = string }
variable "region" { type = string }
variable "zones" { type = list(string) }
variable "primary_zone" { type = string }
variable "prefix" { type = string }
variable "labels" { type = map(string) }

variable "network_name" { type = string }
variable "subnet_name" { type = string }
variable "pods_range" { type = string }
variable "services_range" { type = string }
variable "master_cidr" { type = string }

variable "master_authorized_cidrs" { type = list(string) }
variable "deletion_protection" { type = bool }

variable "general_machine_type" { type = string }
variable "scan_engine_machine_type" { type = string }
variable "poc_machine_type" { type = string }

variable "database_encryption_key" {
  type    = string
  default = null
}
