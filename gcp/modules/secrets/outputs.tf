output "secret_ids" {
  value = concat(
    [for s in google_secret_manager_secret.this : s.secret_id],
    [for s in google_secret_manager_secret.deferred : s.secret_id],
  )
}

output "env_secret_ids" {
  description = "Environment variable name to Secret Manager secret id, for the workloads that read them via secret_key_ref. Includes deferred-version secrets, whose containers always exist."
  value = merge(
    { for k, s in google_secret_manager_secret.this : k => s.secret_id },
    { for k, s in google_secret_manager_secret.deferred : k => s.secret_id },
  )
}

output "version_names" {
  description = "Secret id (without prefix) to the full name of its current version, for services that take a secret version (Artifact Registry upstream credentials)."
  value       = { for k, v in google_secret_manager_secret_version.this : k => v.name }
}
