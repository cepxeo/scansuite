variable "project_id" { type = string }
variable "region" { type = string }
variable "prefix" { type = string }
variable "subnet_cidr" { type = string }
variable "nat_ip_count" { type = number }

variable "psa_cidr" {
  description = "Range reserved for Cloud SQL and Memorystore (private services access)."
  type        = string
  default     = "10.30.0.0/16"
}

variable "poc_network" {
  description = "\"own\": the PoC runner job in a VPC of its own (internet through its own NAT, or Google APIs only with egress_mode = \"none\"). \"shared\": its subnet in this VPC behind a firewall rule."
  type        = string
  default     = "own"

  validation {
    condition     = contains(["own", "shared"], var.poc_network)
    error_message = "poc_network is \"own\" or \"shared\"."
  }
}

variable "poc_subnet_cidr" {
  description = "Subnet of the PoC runner job (Direct VPC egress: a /26 or larger). With poc_network = \"shared\" it must not overlap subnet_cidr or psa_cidr."
  type        = string
  default     = "10.20.8.0/26"
}

variable "poc_denied_ranges" {
  description = "Further ranges the PoC runner may not reach: public ones with poc_network = \"own\" (private ones are closed already), corporate ones with \"shared\"."
  type        = list(string)
  default     = []
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
