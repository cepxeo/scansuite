variable "prefix" { type = string }
variable "suffix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "tags" { type = map(string) }

variable "vnet_id" { type = string }
variable "subnet_id" { type = string }

variable "sku_name" { type = string }
variable "storage_mb" { type = number }
variable "highly_available" { type = bool }

variable "administrator_login" { type = string }

variable "administrator_password" {
  type      = string
  sensitive = true
}
