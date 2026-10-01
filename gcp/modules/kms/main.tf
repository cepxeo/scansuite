###############################################################################
# Application-layer encryption key for Kubernetes Secrets in etcd.
# Optional (var.enable_secrets_encryption) - Google already encrypts etcd at
# rest with its own keys; this adds a key you control and can revoke.
###############################################################################

variable "project_id" { type = string }
variable "project_number" { type = string }
variable "region" { type = string }
variable "prefix" { type = string }

resource "google_kms_key_ring" "this" {
  project  = var.project_id
  name     = "${var.prefix}-keyring"
  location = var.region
}

resource "google_kms_crypto_key" "etcd" {
  name            = "${var.prefix}-etcd"
  key_ring        = google_kms_key_ring.this.id
  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = false
  }
}

# GKE encrypts with its own service agent identity, not the node identity.
resource "google_kms_crypto_key_iam_member" "gke" {
  crypto_key_id = google_kms_crypto_key.etcd.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${var.project_number}@container-engine-robot.iam.gserviceaccount.com"
}

output "crypto_key_id" {
  value      = google_kms_crypto_key.etcd.id
  depends_on = [google_kms_crypto_key_iam_member.gke]
}
