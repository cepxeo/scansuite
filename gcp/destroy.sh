#!/usr/bin/env bash
#
# Tear the deployment down, in the order that actually works.
#
#   ./destroy.sh                     asks you to type the project id
#   ./destroy.sh -y                  no question (scripts)
#   ./destroy.sh --delete-artifacts  also delete the artifact bucket and the
#                                    scan artifacts in it (kept by default)
#
# Extra arguments go to terraform. Safe to re-run: after a partial teardown it
# carries on with what is left in the state.
#
#   1. Deletion protection (deletion_protection = true) is switched off on the
#      resources that carry it - Cloud SQL, GKE, the Cloud Run services - since
#      they refuse to be deleted otherwise.
#      The database user and the private services connection are set to be
#      abandoned rather than deleted (neither can be deleted while in use), in
#      deployments made before that.
#   2. The artifact bucket is released from the state and kept, unless
#      --delete-artifacts: then it is made deletable with its contents.
#   3. GKE: the Kubernetes objects go first, while the cluster that holds them
#      still exists; if it is already gone they are dropped from the state.
#   4. Everything else.
#
# Some names outlive their resources (see the notes printed at the end).

set -euo pipefail

cd "$(dirname "$0")"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

ASSUME_YES=0
DELETE_ARTIFACTS=0
args=()
for arg in "$@"; do
  case "${arg}" in
    -y|--yes)           ASSUME_YES=1 ;;
    --delete-artifacts) DELETE_ARTIFACTS=1 ;;
    *)                  args+=("${arg}") ;;
  esac
done

STATE="$(terraform state list 2>/dev/null || true)"
[[ -n "${STATE}" ]] || die "No Terraform state here - nothing to destroy."

tf_var() { terraform console -input=false <<<"$1" 2>/dev/null | tr -d '"\r'; }
in_state() { grep -q "^$1" <<<"${STATE}"; }
# The name of a resource in the state, empty when it is not there (a re-run
# after a partial teardown).
state_name() {
  terraform state show -no-color "$1" 2>/dev/null |
    awk -F'"' '$1 ~ /^ *name *= *$/ {print $2; exit}' || true
}

PROJECT="$(tf_var var.project_id)"
PLATFORM="$(tf_var var.platform)"
PLATFORM="${PLATFORM:-cloudrun}"
PROTECTED="$(tf_var var.deletion_protection)"
[[ -n "${PROJECT}" ]] || die "could not read project_id"

if [[ "${ASSUME_YES}" != 1 ]]; then
  what="everything this configuration built in ${PROJECT}, including the database"
  [[ "${DELETE_ARTIFACTS}" == 1 ]] && what="${what} and the scan artifacts"
  read -r -p "Destroy ${what}? Type the project id: " answer
  [[ "${answer}" == "${PROJECT}" ]] || die "Not confirmed."
fi

log "Platform ${PLATFORM}, project ${PROJECT}"

release=(-var deletion_protection=false)
[[ "${DELETE_ARTIFACTS}" == 1 ]] && release+=(-var artifact_bucket_force_destroy=true)

# 1-2. Write the released flags into the state; terraform destroy reads them
# from there, not from the configuration.
targets=()
if [[ "${PROTECTED}" == "true" ]]; then
  in_state 'module.cloudsql.google_sql_database_instance.this' && targets+=(-target=module.cloudsql.google_sql_database_instance.this)
  in_state 'module.gke\[0\].google_container_cluster.this' && targets+=(-target='module.gke[0].google_container_cluster.this')
  in_state 'module.cloudrun\[0\]' && targets+=(-target='module.cloudrun[0]')
fi
# Deployments made before these were set to be abandoned still have them set
# to be deleted in the state.
in_state 'module.cloudsql.google_sql_user.scansuite' && targets+=(-target=module.cloudsql.google_sql_user.scansuite)
in_state 'module.network.google_service_networking_connection.psa' && targets+=(-target=module.network.google_service_networking_connection.psa)
BUCKET=""
if in_state 'module.storage.google_storage_bucket.artifacts'; then
  BUCKET="$(state_name module.storage.google_storage_bucket.artifacts)"
  [[ "${DELETE_ARTIFACTS}" == 1 ]] && targets+=(-target=module.storage.google_storage_bucket.artifacts)
fi
if [[ ${#targets[@]} -gt 0 ]]; then
  what="deletion protection"
  [[ "${DELETE_ARTIFACTS}" == 1 ]] && what="${what} and the artifact bucket"
  log "Releasing ${what}"
  terraform apply -input=false -auto-approve "${release[@]}" "${targets[@]}" ${args[@]+"${args[@]}"}
fi
if [[ -n "${BUCKET}" && "${DELETE_ARTIFACTS}" != 1 ]]; then
  log "Keeping the artifact bucket ${BUCKET} (pass --delete-artifacts to delete it)"
  terraform state rm module.storage.google_storage_bucket.artifacts >/dev/null
fi

# 3. GKE: the Kubernetes provider needs the cluster to delete its own objects.
if [[ "${PLATFORM}" == "gke" ]] && in_state 'module.kubernetes'; then
  log "Load balancer and Kubernetes workloads"
  if ! terraform destroy -input=false -auto-approve "${release[@]}" \
      -target=module.lb -target=module.kubernetes ${args[@]+"${args[@]}"}; then
    cluster="$(state_name 'module.gke[0].google_container_cluster.this')"
    if [[ -z "${cluster}" ]] || ! gcloud container clusters describe "${cluster}" --project "${PROJECT}" \
        --region "$(tf_var var.region)" >/dev/null 2>&1; then
      log "The cluster is gone; dropping its Kubernetes objects from the state"
      terraform state list | grep '^module.kubernetes' | while read -r address; do
        terraform state rm "${address}" >/dev/null
      done
    else
      die "the Kubernetes objects could not be deleted while the cluster exists; fix the error above and re-run"
    fi
  fi
fi

# 4.
log "Destroying everything else"
KMS_IN_STATE="$(terraform state list 2>/dev/null | grep -c '^module.kms' || true)"
CLOUDSQL="$(state_name module.cloudsql.google_sql_database_instance.this)"
output="$(mktemp)"
trap 'rm -f "${output}"' EXIT
if ! terraform destroy -input=false -auto-approve "${release[@]}" ${args[@]+"${args[@]}"} 2>&1 | tee "${output}"; then
  # Cloud Run's direct VPC egress holds addresses in the subnet for up to two
  # hours after its services are gone, and only Google can release them.
  if grep -q 'serverless-ipv4-' "${output}"; then
    die "Cloud Run still holds addresses in the subnet. Google releases them up to two hours after the services are deleted; re-run ./destroy.sh then. Nothing left is billed."
  fi
  die "terraform destroy failed; fix the error above and re-run"
fi

log "Done"
cat <<EOF

Left behind on purpose, or by Google:
EOF
if [[ -n "${BUCKET}" && "${DELETE_ARTIFACTS}" != 1 ]]; then
  cat <<EOF
  - The artifact bucket ${BUCKET}, with the scan artifacts. A new deployment
    with the same name_prefix in this project needs it back in the state:
      terraform import module.storage.google_storage_bucket.artifacts ${BUCKET}
    or delete it:  gcloud storage rm --recursive gs://${BUCKET}
EOF
fi
if [[ -n "${CLOUDSQL}" ]]; then
  cat <<EOF
  - Cloud SQL keeps the name ${CLOUDSQL} reserved for about a week. To deploy
    again sooner, set cloudsql_name to another name.
EOF
fi
if [[ "${KMS_IN_STATE}" -gt 0 ]]; then
  cat <<EOF
  - Cloud KMS never deletes key rings; the crypto key's versions are scheduled
    for destruction. A new deployment with the same name_prefix must import the
    key ring and key (terraform import 'module.kms[0].google_kms_key_ring.this'
    projects/${PROJECT}/locations/<region>/keyRings/<prefix>-keyring), or use
    another name_prefix.
EOF
fi
