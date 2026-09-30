variable "prefix" { type = string }
variable "suffix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "tags" { type = map(string) }

variable "sku" {
  description = "Basic in dev; Premium in prod for private endpoints."
  type        = string
  default     = "Basic"
}

variable "pull_principals" {
  description = "Name -> principal id of every identity that pulls images."
  type        = map(string)
}
