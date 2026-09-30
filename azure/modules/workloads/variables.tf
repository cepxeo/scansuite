variable "prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "tags" { type = map(string) }

variable "environment_id" { type = string }
variable "scan_profile_name" { type = string }

variable "deploy_workloads" {
  description = "Off creates only Redis (platform); on adds the apps and jobs."
  type        = bool
}

variable "registry_server" { type = string }
variable "image_tag" { type = string }

variable "image_digests" {
  description = "Image name -> sha256 digest; an image with a digest is deployed by digest."
  type        = map(string)
}

variable "identities" {
  description = "app, poc, migrate -> {id, client_id, principal_id}."
  type = map(object({
    id           = string
    client_id    = string
    principal_id = string
  }))
}

variable "dispatcher_role_definition_id" { type = string }

variable "secret_ids" {
  description = "Key Vault secret name -> versionless id."
  type        = map(string)
}

variable "config" {
  description = "Non-secret environment shared by every workload (AZURE_CLIENT_ID is added per workload)."
  type        = map(string)
}

variable "poc_installation_secrets" {
  description = "Pass worker-poc SECRET_KEY and the wrapping keys (images whose work_poc.py still demands them)."
  type        = bool
}

variable "web_allowed_cidrs" { type = list(string) }
variable "web_min_replicas" { type = number }
variable "web_max_replicas" { type = number }

variable "scan_cpu" { type = number }
variable "scan_memory" { type = string }
variable "scan_timeout_seconds" { type = number }
