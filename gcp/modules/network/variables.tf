variable "project_id" { type = string }
variable "region" { type = string }
variable "prefix" { type = string }
variable "subnet_cidr" { type = string }
variable "pods_cidr" { type = string }
variable "services_cidr" { type = string }
variable "nat_ip_count" { type = number }

variable "gke" {
  description = "Create the pod and service ranges and the health-check firewall rule GKE needs."
  type        = bool
  default     = false
}

variable "psa_cidr" {
  description = "Range reserved for Cloud SQL and Memorystore (private services access)."
  type        = string
  default     = "10.30.0.0/16"
}

variable "egress_mode" {
  description = "\"nat\": Cloud NAT on reserved external addresses. \"none\": no internet route, Google APIs through Private Google Access."
  type        = string
  default     = "nat"
}

variable "google_apis_vip" {
  description = "With egress_mode = \"none\": \"private\" (all Google APIs) or \"restricted\" (VPC Service Controls)."
  type        = string
  default     = "private"
}

variable "dns_forwarding_zones" {
  description = "Domain -> corporate DNS server addresses, for internal names the workloads resolve."
  type        = map(list(string))
  default     = {}
}

variable "dns_inbound_forwarding" {
  description = "Create inbound DNS forwarders in the subnet for the corporate DNS servers to forward to."
  type        = bool
  default     = false
}
