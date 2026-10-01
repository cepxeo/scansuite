###############################################################################
# Artifact Registry.
#
#   <prefix>            a standard repository: images pushed from a local build
#                       (deploy.sh with LOCAL_IMAGES=1, or scripts/mirror-images.sh).
#   <prefix>-dockerhub  a remote repository in front of Docker Hub, the default
#                       source. Cloud Run cannot pull private Docker Hub images
#                       itself, so every workload reads the appsec4u images
#                       through this repository, which authenticates to Docker
#                       Hub with the token in Secret Manager.
#
# There are no scanner images: this deployment runs static analysis with no
# Docker daemon. See README, "Static analysis only".
###############################################################################

variable "project_id" { type = string }
variable "region" { type = string }
variable "prefix" { type = string }
variable "labels" { type = map(string) }
variable "reader_members" { type = list(string) }

variable "dockerhub_username" {
  type    = string
  default = ""
}

variable "dockerhub_token_secret_version" {
  description = "Secret Manager version name of the Docker Hub token (projects/.../secrets/.../versions/N). Empty makes the remote repository pull anonymously."
  type        = string
  default     = ""
}

locals {
  authenticated = var.dockerhub_username != "" && var.dockerhub_token_secret_version != ""
  repositories = {
    local  = google_artifact_registry_repository.this.name
    remote = google_artifact_registry_repository.dockerhub.name
  }
}

resource "google_artifact_registry_repository" "this" {
  project       = var.project_id
  location      = var.region
  repository_id = var.prefix
  description   = "ScanSuite application images"
  format        = "DOCKER"
  labels        = var.labels

  docker_config {
    immutable_tags = false
  }
}

resource "google_artifact_registry_repository" "dockerhub" {
  project       = var.project_id
  location      = var.region
  repository_id = "${var.prefix}-dockerhub"
  description   = "ScanSuite images read through from Docker Hub"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  labels        = var.labels

  remote_repository_config {
    description = "Docker Hub"

    docker_repository {
      public_repository = "DOCKER_HUB"
    }

    dynamic "upstream_credentials" {
      for_each = local.authenticated ? [1] : []
      content {
        username_password_credentials {
          username                = var.dockerhub_username
          password_secret_version = var.dockerhub_token_secret_version
        }
      }
    }
  }
}

resource "google_artifact_registry_repository_iam_member" "readers" {
  for_each = {
    for pair in setproduct(keys(local.repositories), var.reader_members) :
    "${pair[0]}:${pair[1]}" => { repository = local.repositories[pair[0]], member = pair[1] }
  }

  project    = var.project_id
  location   = var.region
  repository = each.value.repository
  role       = "roles/artifactregistry.reader"
  member     = each.value.member
}

output "repository_url" {
  description = "The standard repository, for pushed images."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.this.repository_id}"
}

output "remote_repository_url" {
  description = "The remote repository in front of Docker Hub."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.dockerhub.repository_id}"
}
