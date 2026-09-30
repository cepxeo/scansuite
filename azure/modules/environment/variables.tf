variable "prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "tags" { type = map(string) }

variable "subnet_id" { type = string }
variable "log_analytics_workspace_id" { type = string }

variable "internal" {
  description = "Internal load balancer only (prod behind Front Door Private Link). Dev is external with an IP allowlist on the web app."
  type        = bool
  default     = false
}

variable "dedicated_scan_profile" {
  description = "Add a Dedicated E4 profile (4 vCPU / 32 GiB, min 0 nodes) for the scan job."
  type        = bool
  default     = false
}

variable "dedicated_scan_max_nodes" {
  type    = number
  default = 2
}

