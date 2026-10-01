provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

data "google_client_config" "default" {}

data "google_project" "this" {
  project_id = var.project_id
}

# The Kubernetes provider is configured from the cluster this same root module
# creates, which is why deploy.sh applies in two phases when platform = "gke":
# phase 1 builds the cluster, phase 2 fills it.  See README, "Why deploy.sh runs
# Terraform twice".
#
# With platform = "cloudrun" no cluster exists and no Kubernetes resource is
# planned, so these values are empty strings the provider never uses.
provider "kubernetes" {
  host                   = length(module.gke) > 0 ? "https://${module.gke[0].endpoint}" : ""
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = length(module.gke) > 0 ? base64decode(module.gke[0].ca_certificate) : ""
}
