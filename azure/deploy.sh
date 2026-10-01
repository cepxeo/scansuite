#!/usr/bin/env bash
#
# One command, complete deployment of ScanSuite on Azure Container Apps.
#
#   1. Platform (deploy_workloads=false), first run only: network, database,
#      vault, storage, registry, Container Apps environment, Redis. Needs no
#      licence or image. Skipped once the workloads exist, because that apply
#      would delete them.
#   2. Image import: teams-web, teams-worker and teams-worker-poc copied into
#      the deployment's registry, server side (az acr import).
#   3. Workloads: web, workers, the scan and migrate jobs.
#   4. The migrate job, judged by its execution status. Console logs can reach
#      Log Analytics ten minutes late, so they are never the signal. Only when
#      the images changed: migrating cancels the scans in flight.
#
# Idempotent: re-running it is the normal way to apply a change or a new
# image tag. Extra arguments go to both terraform apply calls. MIGRATE=1 runs
# the migration even when the images are the ones last migrated.
#
# Docker Hub credentials for the import, when the repositories are private:
#   DOCKERHUB_USERNAME, DOCKERHUB_TOKEN  (environment only; never in state)
set -euo pipefail

cd "$(dirname "$0")"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

command -v terraform >/dev/null 2>&1 || die "terraform is not installed"
command -v az >/dev/null 2>&1 || die "az (Azure CLI) is not installed"
az account show >/dev/null 2>&1 || die "not signed in to Azure. Run: az login"

if [[ ! -f terraform.tfvars && -z "${TF_VAR_subscription_id:-}" ]]; then
  die "no terraform.tfvars and no TF_VAR_subscription_id. Copy terraform.tfvars.example and set subscription_id."
fi

tf_var() { terraform console -input=false <<<"$1" 2>/dev/null | tr -d '"\r'; }

log "terraform init"
# The registry query occasionally has its connection reset; try again.
for attempt in 1 2 3; do
  terraform init -input=false >/dev/null && break
  [[ "${attempt}" == 3 ]] && die "terraform init failed three times"
  sleep 10
done

SUBSCRIPTION="$(tf_var var.subscription_id)"
[[ -n "${SUBSCRIPTION}" ]] || die "could not read subscription_id"
az account set --subscription "${SUBSCRIPTION}"

# The provider registers nothing itself (resource_provider_registrations =
# "none"), so register exactly what this configuration uses.
log "Registering resource providers"
for ns in Microsoft.App Microsoft.ContainerRegistry Microsoft.DBforPostgreSQL Microsoft.KeyVault \
          Microsoft.ManagedIdentity Microsoft.Network Microsoft.OperationalInsights Microsoft.Storage \
          Microsoft.Insights; do
  state="$(az provider show -n "$ns" --query registrationState -o tsv 2>/dev/null || true)"
  if [[ "${state}" != "Registered" ]]; then
    az provider register -n "$ns" --wait >/dev/null
    echo "  registered ${ns}"
  fi
done

# Some subscription offers (Visual Studio, for one) are barred from PostgreSQL
# Flexible Server in some regions - Germany West Central and West Europe among
# them - and Azure says so only after the environment has spent 25 minutes
# building. Ask first.
LOCATION="$(tf_var var.location)"
pg_versions="$(az rest --method GET \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION}/providers/Microsoft.DBforPostgreSQL/locations/${LOCATION}/capabilities?api-version=2024-08-01" \
  --query "value[0].supportedServerVersions[].name" -o tsv 2>/dev/null | tr -d '\r' | tr '\n' ' ' || true)"
if [[ " ${pg_versions} " != *" 16 "* ]]; then
  die "PostgreSQL Flexible Server 16 is not available to this subscription in ${LOCATION} (offered: ${pg_versions:-none}). Pick another location, or ask Microsoft to lift the regional restriction."
fi

# The workloads cannot start without the licence of image_tag; say so before the
# 25-minute platform build rather than after it.
DEPLOY_WORKLOADS="$(tf_var var.deploy_workloads)"
TAG="$(tf_var var.image_tag)"
if [[ "${DEPLOY_WORKLOADS}" == "true" ]]; then
  KEY_DIR="$(tf_var local.key_dir)"
  LICENCE="$(tf_var local.licence_name)"
  if [[ -z "${LICENCE}" || ! -f "${KEY_DIR}/${LICENCE}" ]]; then
    die "no licence for image tag ${TAG}: put your <name>_${TAG}.lic in ${KEY_DIR}/ (exactly one *.lic, or set pyarmor_license_file). To build only the platform first, set deploy_workloads = false."
  fi
  [[ "${LICENCE}" == *"_${TAG}.lic" ]] ||
    echo "  warning: ${LICENCE} does not look like the licence of image tag ${TAG}; the containers will not start if they differ" >&2
fi

# The platform-only apply exists for the first run, when the registry must
# exist before any app can pull from it. Once the workloads are in the state it
# must be skipped: deploy_workloads=false tells Terraform to delete them.
if terraform state list 2>/dev/null | grep -q '^module\.workloads\.azurerm_container_app\.web\['; then
  log "Phase 1/3 - platform already built; the workloads are applied together with it below"
else
  log "Phase 1/3 - platform (about 25 minutes on a first run, most of it the Container Apps environment)"
  terraform apply -input=false -auto-approve -var deploy_workloads=false "$@"
fi

RG="$(terraform output -raw resource_group)"
ACR="$(terraform output -raw registry)"
SOURCE="$(terraform output -raw image_registry)"
TAG="$(terraform output -raw image_tag)"

# Images present in the local Docker engine (a fresh update-scansuite.sh build)
# are pushed through az acr login - the Azure session, no registry password.
# Otherwise the registry imports them server side, which for the private
# appsec4u repositories needs DOCKERHUB_USERNAME and DOCKERHUB_TOKEN. A local
# copy of the tag wins, so remove a stale one before deploying someone else's
# build.
log "Phase 2/3 - images ${SOURCE}/*:${TAG} into ${ACR}"
credentials=()
if [[ -n "${DOCKERHUB_USERNAME:-}" && -n "${DOCKERHUB_TOKEN:-}" ]]; then
  credentials=(--username "${DOCKERHUB_USERNAME}" --password "${DOCKERHUB_TOKEN}")
fi
LOGIN_SERVER="$(az acr show -n "${ACR}" --query loginServer -o tsv)"
logged_in=""
for image in teams-web teams-worker teams-worker-poc; do
  local_ref="${SOURCE#docker.io/}/${image}:${TAG}"
  if command -v docker >/dev/null 2>&1 && docker image inspect "${local_ref}" >/dev/null 2>&1; then
    if [[ -z "${logged_in}" ]]; then
      az acr login -n "${ACR}" >/dev/null
      logged_in=1
    fi
    docker tag "${local_ref}" "${LOGIN_SERVER}/${image}:${TAG}"
    docker push -q "${LOGIN_SERVER}/${image}:${TAG}" >/dev/null
    echo "  ${image}:${TAG} (pushed from the local engine)"
  else
    az acr import --name "${ACR}" --source "${SOURCE}/${image}:${TAG}" --image "${image}:${TAG}" \
      --force "${credentials[@]}" >/dev/null \
      || die "could not import ${SOURCE}/${image}:${TAG}; for private repositories set DOCKERHUB_USERNAME and DOCKERHUB_TOKEN, or build the images locally"
    echo "  ${image}:${TAG} (imported)"
  fi
done

# Deploy by digest: release tags are reused for every build of a licence, so
# the tag alone would leave the apps on the previous image.
digests=()
for image in teams-web teams-worker teams-worker-poc; do
  digest="$(az acr manifest show-metadata -r "${ACR}" -n "${image}:${TAG}" --query digest -o tsv 2>/dev/null | tr -d '\r' || true)"
  [[ "${digest}" == sha256:* ]] || die "could not read the digest of ${image}:${TAG} in ${ACR}"
  digests+=("\"${image}\": \"${digest}\"")
  echo "  ${image} ${digest}"
done
printf '{\n  "image_digests": {%s}\n}\n' "$(IFS=,; echo "${digests[*]}")" > images.auto.tfvars.json

if [[ "${DEPLOY_WORKLOADS}" != "true" ]]; then
  log "deploy_workloads = false in terraform.tfvars: stopping after the platform."
  terraform output
  exit 0
fi

log "Phase 3/3 - workloads"
terraform apply -input=false -auto-approve "$@"

MIGRATE_JOB="$(terraform output -raw migrate_job_name)"
# The migration also cancels every scan still in flight, which is right for a
# new release but wrong for a settings change: scan executions keep running
# through an apply that leaves the images alone. So migrate only when the
# images differ from the last ones migrated here (MIGRATE=1 forces it).
if [[ "${MIGRATE:-}" != "1" && -f images.migrated.json ]] && cmp -s images.auto.tfvars.json images.migrated.json; then
  log "Images unchanged since their last migration: skipping it, so scans in flight keep running"
  log "Done"
  terraform output
  exit 0
fi
log "Running migrations (${MIGRATE_JOB})"
EXECUTION="$(az containerapp job start -g "${RG}" -n "${MIGRATE_JOB}" --query name -o tsv)"
echo "  execution ${EXECUTION}"
status=""
for _ in $(seq 1 180); do
  status="$(az containerapp job execution show -g "${RG}" -n "${MIGRATE_JOB}" \
    --job-execution-name "${EXECUTION}" --query properties.status -o tsv 2>/dev/null || true)"
  case "${status}" in
    Succeeded) echo "  ${status}"; break ;;
    Failed|Stopped|Degraded) die "migration ${EXECUTION} ended ${status}. Its log: Log Analytics, ContainerAppConsoleLogs_CL where ContainerGroupName_s startswith '${EXECUTION}' (allow a few minutes)." ;;
  esac
  sleep 10
done
[[ "${status}" == "Succeeded" ]] || die "migration ${EXECUTION} still ${status:-unknown} after 30 minutes"
cp images.auto.tfvars.json images.migrated.json

log "Done"
terraform output

cat <<'EOF'

Next:
  1. Open the url above now. A new installation shows the setup page, where
     the first account - administrator of its team and of the installation -
     is created. Whoever reaches the page first gets that account, so do it
     straight away (web_allowed_cidrs limits who can reach it).
  2. Configure the AI provider on the System AI card under System Settings ->
     Shared services: an Azure OpenAI /v1 endpoint through the OpenAI
     provider, or any other supported provider.
  3. This deployment runs static analysis only: Container Apps has no Docker
     daemon for the dynamic and infrastructure scanners.
EOF
