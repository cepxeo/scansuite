variable "prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "tags" { type = map(string) }

variable "daily_quota_gb" { type = number }
variable "alert_email" { type = string }
