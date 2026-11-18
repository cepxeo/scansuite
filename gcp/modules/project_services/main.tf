variable "project_id" { type = string }

locals {
  services = [
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "sqladmin.googleapis.com",
    "redis.googleapis.com",
    "servicenetworking.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "aiplatform.googleapis.com",
    "storage.googleapis.com",
    "cloudkms.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "dns.googleapis.com",
    "certificatemanager.googleapis.com",
    "run.googleapis.com",
  ]
}

resource "google_project_service" "this" {
  for_each = toset(local.services)

  project = var.project_id
  service = each.value

  # Never turn an API off underneath a resource that is still using it.
  disable_on_destroy         = false
  disable_dependent_services = false
}

# Enabling an API returns before its service agent exists. Everything
# downstream depends on this module, so absorb the race once, here.
resource "time_sleep" "propagation" {
  depends_on      = [google_project_service.this]
  create_duration = "45s"
}

output "enabled" {
  value = time_sleep.propagation.id
}

