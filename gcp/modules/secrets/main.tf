###############################################################################
# Secret Manager.
#
# Canonical, auditable, rotatable copy of every credential the deployment uses.
# Everything here is a string secret consumed as an environment variable - the
# /key files are no longer mounted; they are injected as base64 strings and
# decoded at container start.
#
# Three shapes:
#   values           container + version, always. Values may be generated
#                    (random passwords, the Redis auth string) and so unknown
#                    until apply; which secrets exist must not depend on them.
#   optional_values  container + version only when the value is not empty
#                    (an unconfigured optional integration leaves no trace).
#                    The values must be known while planning: variables, files.
#   deferred_values  container always created; version created only when a
#                    value is supplied. This is for the llm-scansuit key, whose
#                    JSON is added out of band so it never enters Terraform
#                    state, while the container still has to exist for the
#                    workloads to reference it.
###############################################################################

locals {
  # Names only: a set derived from the sensitive maps cannot drive for_each,
  # but which secrets exist is not itself a secret.
  present = nonsensitive(toset(concat(keys(var.values), [
    for k in keys(var.optional_values) : k if trimspace(var.optional_values[k] == null ? "" : var.optional_values[k]) != ""
  ])))
  all_values = merge(var.values, var.optional_values)
  deferred   = nonsensitive(toset(keys(var.deferred_values)))
  # Only the deferred secrets that actually have a value get a version.
  deferred_present = nonsensitive(toset([
    for k in keys(var.deferred_values) : k if trimspace(var.deferred_values[k] == null ? "" : var.deferred_values[k]) != ""
  ]))
}

###############################################################################
# Regular string secrets
###############################################################################

resource "google_secret_manager_secret" "this" {
  for_each = local.present

  project   = var.project_id
  secret_id = "${var.prefix}-${each.key}"
  labels    = var.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "this" {
  for_each = local.present

  secret      = google_secret_manager_secret.this[each.key].id
  secret_data = local.all_values[each.key]
}

###############################################################################
# Deferred-version secrets (containers always; versions out of band)
###############################################################################

resource "google_secret_manager_secret" "deferred" {
  for_each = local.deferred

  project   = var.project_id
  secret_id = "${var.prefix}-${each.value}"
  labels    = var.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "deferred" {
  for_each = local.deferred_present

  secret      = google_secret_manager_secret.deferred[each.value].id
  secret_data = var.deferred_values[each.value]
}

###############################################################################
# Access
###############################################################################

resource "google_secret_manager_secret_iam_member" "accessors" {
  for_each = {
    for pair in setproduct(tolist(local.present), var.accessor_members) :
    "${pair[0]}:${pair[1]}" => { secret = pair[0], member = pair[1] }
  }

  project   = var.project_id
  secret_id = google_secret_manager_secret.this[each.value.secret].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value.member
}

resource "google_secret_manager_secret_iam_member" "deferred_accessors" {
  for_each = {
    for pair in setproduct(tolist(local.deferred), var.accessor_members) :
    "${pair[0]}:${pair[1]}" => { secret = pair[0], member = pair[1] }
  }

  project   = var.project_id
  secret_id = google_secret_manager_secret.deferred[each.value.secret].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value.member
}
