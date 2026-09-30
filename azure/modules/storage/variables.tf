variable "prefix" { type = string }
variable "suffix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "tags" { type = map(string) }

variable "aca_subnet_id" { type = string }

variable "replication_type" {
  description = "LRS in dev, ZRS in prod."
  type        = string
  default     = "LRS"
}

variable "retention_days" { type = number }

variable "writer_principal_id" {
  description = "The app identity, the only principal that reads and writes artifacts."
  type        = string
}
