variable "prefix" { type = string }
variable "suffix" {
  description = "Random suffix shared by the globally named resources."
  type        = string
}
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "tags" { type = map(string) }
variable "tenant_id" { type = string }

variable "operator_principal_id" {
  description = "Whoever runs Terraform; granted Key Vault Secrets Officer to write the secrets."
  type        = string
}

variable "purge_protection" { type = bool }

variable "secret_names" {
  description = "Names of the secrets to create (kept apart from the values so for_each can plan)."
  type        = list(string)
}

variable "secrets" {
  description = "Secret name -> value."
  type        = map(string)
  sensitive   = true
}

variable "principals" {
  description = "Reader name -> principal (object) id."
  type        = map(string)
}

variable "readers" {
  description = "Secret name -> reader names allowed to read it."
  type        = map(list(string))
}
