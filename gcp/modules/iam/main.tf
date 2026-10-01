###############################################################################
# Three Google service accounts.
#
#   app  web, scan-engine and celery-beat. They all need Cloud SQL, the
#        artifact bucket and Vertex AI, so splitting them would buy separation
#        on paper only.
#   poc  worker-poc. It executes model-generated exploit code, so it gets the
#        database and nothing else - no bucket, no Vertex, and no /key mount.
#   migrate  the Cloud Run migration job: Cloud SQL, logs and the secrets it
#        starts with. Every workload connects as the one database account (the
#        schema owner) since the application dropped its restricted role; this
#        account keeps the migration's identity separate in the audit log.
#
# Both are reachable from Kubernetes through Workload Identity. The app account
# ALSO gets an exported JSON key, because database/object_store.py forces
# GOOGLE_APPLICATION_CREDENTIALS to a file path and fails closed when the file
# is missing - Application Default Credentials are never consulted. That key is
# the one long-lived credential in this deployment; see README, "The /key
# problem", for the small code change that removes it.
###############################################################################

resource "google_service_account" "app" {
  project      = var.project_id
  account_id   = "${var.prefix}-app"
  display_name = "ScanSuite application (web, scan engine, beat)"
}

resource "google_service_account" "poc" {
  project      = var.project_id
  account_id   = "${var.prefix}-poc"
  display_name = "ScanSuite PoC executor"
}

resource "google_service_account" "migrate" {
  project      = var.project_id
  account_id   = "${var.prefix}-migrate"
  display_name = "ScanSuite migration job"
}

###############################################################################
# The LLM / storage identity
#
# No key is generated here any more.  The application authenticates to Cloud
# Storage and Vertex AI with an existing, externally managed service account -
# llm-scansuit - whose key JSON is injected as a secret and written to
# /key/key.json at container start.  This
# module only grants that account the roles it needs on resources we own; the
# account itself, and its key, live outside Terraform.  Leaving it empty skips
# the grants (useful before the account is known, or when it already holds the
# roles).
###############################################################################

locals {
  grant_llm = var.llm_service_account_email != ""
}

resource "google_project_iam_member" "llm_vertex" {
  count = local.grant_llm ? 1 : 0

  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${var.llm_service_account_email}"
}

resource "google_storage_bucket_iam_member" "llm_artifacts" {
  count = local.grant_llm ? 1 : 0

  bucket = var.artifact_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${var.llm_service_account_email}"
}

###############################################################################
# Project-level roles
###############################################################################

resource "google_project_iam_member" "app" {
  for_each = toset([
    "roles/cloudsql.client",
    "roles/aiplatform.user",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.app.email}"
}

resource "google_project_iam_member" "poc" {
  for_each = toset([
    "roles/cloudsql.client",
    "roles/logging.logWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.poc.email}"
}

resource "google_project_iam_member" "migrate" {
  for_each = toset([
    "roles/cloudsql.client",
    "roles/logging.logWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.migrate.email}"
}

###############################################################################
# Bucket-level roles
###############################################################################

resource "google_storage_bucket_iam_member" "app_artifacts" {
  bucket = var.artifact_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.app.email}"
}

###############################################################################
# Workload Identity bindings
###############################################################################

# Workload Identity only exists when there is a cluster. On Cloud Run the
# workloads carry the service account directly, and the identity pool these
# members refer to would not exist.
locals {
  app_ksas = var.enable_workload_identity ? ["web", "scan-engine", "worker-admin", "celery-beat"] : []
}

resource "google_service_account_iam_member" "app_wi" {
  for_each = toset(local.app_ksas)

  service_account_id = google_service_account.app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/${each.value}]"
}

resource "google_service_account_iam_member" "poc_wi" {
  count = var.enable_workload_identity ? 1 : 0

  service_account_id = google_service_account.poc.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/worker-poc]"
}
