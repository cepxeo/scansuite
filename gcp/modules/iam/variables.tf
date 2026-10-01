variable "project_id" { type = string }
variable "prefix" { type = string }
variable "namespace" { type = string }
variable "artifact_bucket" { type = string }

variable "enable_workload_identity" {
  description = "Bind the Google service accounts to Kubernetes ones. Only meaningful when platform = gke."
  type        = bool
  default     = false
}

variable "llm_service_account_email" {
  description = "Existing service account (e.g. llm-scansuit) the app authenticates as for Cloud Storage and Vertex AI, via the injected /key/key.json. Empty skips the role grants."
  type        = string
  default     = ""
}
