variable "project_id" { type = string }
variable "region" { type = string }
variable "prefix" { type = string }
variable "labels" { type = map(string) }
variable "retention_days" { type = number }

variable "force_destroy" {
  description = "Let terraform destroy delete the bucket with the artifacts in it. destroy.sh --delete-artifacts sets it."
  type        = bool
  default     = false
}
