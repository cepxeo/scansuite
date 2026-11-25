###############################################################################
# Cloud Storage - replaces SeaweedFS.
#
# database/object_store.py already speaks GCS: set GCP_STORAGE_BUCKET and new
# blobs are written as "gcs:" refs. Everything the static analysis pipeline
# produces lands here - packed source artifacts, AI SAST checkpoints, and
# generated reports.
###############################################################################

resource "google_storage_bucket" "artifacts" {
  project  = var.project_id
  name     = "${var.prefix}-artifacts-${var.project_id}"
  location = var.region
  labels   = var.labels

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.force_destroy

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = var.retention_days
      with_state                 = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 5
    }
    action {
      type = "Delete"
    }
  }
}

# The PoC exchange: the input of each PoC run and the result its runner writes
# back, through signed URLs for those two objects (worker/execution/
# poc_backends.py). The broker deletes both after the run; the lifecycle rule is
# the backstop. No versioning: nothing here is worth keeping.
resource "google_storage_bucket" "poc_exchange" {
  project  = var.project_id
  name     = "${var.prefix}-poc-exchange-${var.project_id}"
  location = var.region
  labels   = var.labels

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  lifecycle_rule {
    condition {
      age = 1
    }
    action {
      type = "Delete"
    }
  }
}
