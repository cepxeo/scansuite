variable "project_id" { type = string }
variable "prefix" { type = string }
variable "labels" { type = map(string) }

variable "accessor_members" {
  description = "IAM members granted secretAccessor on every secret created here."
  type        = list(string)
}

variable "values" {
  description = "Secret id (without prefix) to value. Always created: the values may be unknown until apply."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "deferred_values" {
  description = <<-EOT
    Secret id (without prefix) to value, for secrets whose container must always
    exist but whose version may be supplied out of band. An empty value creates
    the container with no version; a non-empty value also creates the version.
  EOT
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "optional_values" {
  description = "Secret id (without prefix) to value; empty values create nothing. The values must be known while planning (variables or files), since they decide which secrets exist."
  type        = map(string)
  default     = {}
  sensitive   = true
}
