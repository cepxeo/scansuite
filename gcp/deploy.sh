#!/usr/bin/env bash
#
# One command, complete deployment, on either platform.
#
#   1. Preflight: tools, credentials, settings and the licence, before
#      anything is created.
#   2. Images (unless image_* overrides name them): the Artifact Registry
#      repositories are created first, then each image's digest is resolved
#      for image_tag through the remote repository in front of Docker Hub - or,
#      with LOCAL_IMAGES=1, the images in the local Docker engine are pushed to
#      the project's own repository. With source_registry set (an internal
#      registry), they are copied from there into that repository first, signed
#      in with SOURCE_REGISTRY_USERNAME and SOURCE_REGISTRY_TOKEN. The digests go to images.auto.tfvars.json,
#      so a rebuild under the same tag still rolls every workload.
#   3. Cloud Run: the migrate job and what it needs are applied first, the job
#      runs when the images differ from the ones last migrated (MIGRATE=1
#      forces it), and only then do the services roll - they refuse an older
#      schema, and Cloud Run waits for them to start. Migrating cancels every
#      scan in flight: right for a new release, wrong for a settings change.
#      GKE: two applies, since the Kubernetes provider is configured from the
#      cluster this same configuration creates; an init container migrates.
#
# Idempotent: re-running it is the normal way to apply a change or a new image
# tag. Extra arguments go to every terraform apply.

set -euo pipefail

cd "$(dirname "$0")"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

IMAGE_NAMES=(teams-web teams-worker teams-worker-poc)

command -v terraform >/dev/null 2>&1 || die "terraform is not installed (https://developer.hashicorp.com/terraform/downloads)"
command -v gcloud >/dev/null 2>&1 || die "gcloud is not installed (https://cloud.google.com/sdk/docs/install)"
command -v curl >/dev/null 2>&1 || die "curl is not installed"

gcloud auth application-default print-access-token >/dev/null 2>&1 \
  || die "no application default credentials. Run: gcloud auth application-default login"

if [[ ! -f terraform.tfvars && -z "${TF_VAR_project_id:-}" ]]; then
  die "no terraform.tfvars and no TF_VAR_project_id. Copy terraform.tfvars.example and set project_id."
fi

log "terraform init"
# The registry query occasionally has its connection reset; try again.
for attempt in 1 2 3; do
  terraform init -input=false >/dev/null && break
  [[ "${attempt}" == 3 ]] && die "terraform init failed three times"
  sleep 10
done

tf_var() { terraform console -input=false <<<"$1" 2>/dev/null | tr -d '"\r'; }

PROJECT="$(tf_var var.project_id)"
REGION="$(tf_var var.region)"
PLATFORM="$(tf_var var.platform)"
PLATFORM="${PLATFORM:-cloudrun}"
TAG="$(tf_var var.image_tag)"
OVERRIDES="$(tf_var 'var.image_web != "" && var.image_worker != "" && var.image_worker_poc != ""')"
SOURCE="$(tf_var var.source_registry)"
INTERNAL="$(tf_var var.internal_only)"
[[ -n "${PROJECT}" ]] || die "could not read project_id"

gcloud projects describe "${PROJECT}" --format='value(projectId)' >/dev/null 2>&1 \
  || die "project ${PROJECT} does not exist or this account cannot see it"

# Without billing every API enablement and resource fails, late and one by one.
billing="$(gcloud billing projects describe "${PROJECT}" --format='value(billingEnabled)' 2>/dev/null || true)"
case "${billing}" in
  True|true) ;;
  False|false) die "billing is not enabled on ${PROJECT}. Link a billing account first: gcloud billing projects link ${PROJECT} --billing-account=<id>" ;;
  *) echo "  warning: could not read the billing state of ${PROJECT} (no billing.projects.get permission?); continuing" >&2 ;;
esac

# A new installation's setup page belongs to whoever opens it first.
if [[ "$(tf_var var.internal_only)" != "true" && "$(tf_var 'length(var.web_allowed_cidrs)')" == "0" ]]; then
  echo "  warning: web_allowed_cidrs is empty, so the web UI - and the setup page of a new installation - is open to the internet" >&2
fi

# The workloads cannot start without the licence that matches the image; say so
# before a twenty-minute apply rather than after it.
KEY_DIR="$(tf_var local.key_dir)"
LICENCE="$(tf_var local.pyarmor_licence 2>/dev/null || true)"
if [[ -z "${LICENCE}" || "${LICENCE}" == "null" || ! -f "${KEY_DIR}/${LICENCE}" ]]; then
  die "no licence in ${KEY_DIR}/: put your <name>_<code>.lic there (exactly one *.lic, or set pyarmor_license_file)."
fi
if [[ "${OVERRIDES}" != "true" && -n "${SOURCE}" ]]; then
  [[ "${LOCAL_IMAGES:-}" != "1" ]] || die "LOCAL_IMAGES=1 and source_registry both name where the images come from; use one"
  [[ -n "${SOURCE_REGISTRY_USERNAME:-}" && -n "${SOURCE_REGISTRY_TOKEN:-}" ]] ||
    die "source_registry is ${SOURCE}: export SOURCE_REGISTRY_USERNAME and SOURCE_REGISTRY_TOKEN (its robot account and token) to copy the images"
  command -v skopeo >/dev/null 2>&1 || command -v docker >/dev/null 2>&1 ||
    die "copying the images from ${SOURCE} needs skopeo or docker"
fi
if [[ "${OVERRIDES}" != "true" ]]; then
  [[ -n "${TAG}" ]] || die "image_tag is empty: set it to your licence code, the <code> of ${LICENCE%.lic}"
  [[ "${LICENCE}" == *"_${TAG}.lic" ]] ||
    echo "  warning: ${LICENCE} does not look like the licence of image tag ${TAG}; the containers will not start if they differ" >&2
fi

log "Project ${PROJECT}, region ${REGION}, platform ${PLATFORM}"

# Resolve one image's digest through the registry API. The remote repository
# fetches the manifest from Docker Hub on first request.
resolve_digest() { # resolve_digest <repository up to the image name> <image> <tag>
  local host="${1%%/*}" path="${1#*/}" token digest
  token="$(gcloud auth print-access-token)"
  digest="$(curl -fsSI \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json" \
    "https://${host}/v2/${path}/$2/manifests/$3" 2>/dev/null |
    tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" {print $2}')"
  [[ "${digest}" == sha256:* ]] && printf '%s' "${digest}"
}

# Copy the three images from source_registry (an internal Quay, for example)
# into the project's own repository: Cloud Run cannot pull from a private
# registry outside Google Cloud. skopeo copies registry to registry; without
# it, docker pulls and pushes. The source credentials come from the
# environment and are signed out again afterwards, so no token stays behind on
# a shared host.
copy_from_source() { # copy_from_source <destination repository>
  local destination="$1" source_host="${SOURCE%%/*}" destination_host="${1%%/*}" image name
  if command -v skopeo >/dev/null 2>&1; then
    printf '%s' "${SOURCE_REGISTRY_TOKEN}" |
      skopeo login --username "${SOURCE_REGISTRY_USERNAME}" --password-stdin "${source_host}" >/dev/null ||
      die "could not sign in to ${source_host} as ${SOURCE_REGISTRY_USERNAME}"
    gcloud auth print-access-token |
      skopeo login --username oauth2accesstoken --password-stdin "${destination_host}" >/dev/null ||
      die "could not sign in to ${destination_host}"
    for image in "${IMAGE_NAMES[@]}"; do
      name="$(tf_var "var.source_image_names[\"${image}\"]")"
      skopeo copy --all "docker://${SOURCE}/${name}:${TAG}" "docker://${destination}/${image}:${TAG}" >/dev/null ||
        { skopeo logout "${source_host}" >/dev/null 2>&1; die "could not copy ${SOURCE}/${name}:${TAG}"; }
      echo "  ${SOURCE}/${name}:${TAG} -> ${image}:${TAG}"
    done
    skopeo logout "${source_host}" >/dev/null 2>&1 || true
  else
    printf '%s' "${SOURCE_REGISTRY_TOKEN}" |
      docker login --username "${SOURCE_REGISTRY_USERNAME}" --password-stdin "${source_host}" >/dev/null ||
      die "could not sign in to ${source_host} as ${SOURCE_REGISTRY_USERNAME}"
    gcloud auth configure-docker "${destination_host}" --quiet >/dev/null 2>&1
    for image in "${IMAGE_NAMES[@]}"; do
      name="$(tf_var "var.source_image_names[\"${image}\"]")"
      { docker pull -q "${SOURCE}/${name}:${TAG}" >/dev/null &&
        docker tag "${SOURCE}/${name}:${TAG}" "${destination}/${image}:${TAG}" &&
        docker push -q "${destination}/${image}:${TAG}" >/dev/null; } ||
        { docker logout "${source_host}" >/dev/null 2>&1; die "could not copy ${SOURCE}/${name}:${TAG}"; }
      echo "  ${SOURCE}/${name}:${TAG} -> ${image}:${TAG}"
    done
    docker logout "${source_host}" >/dev/null 2>&1 || true
  fi
}

if [[ "${OVERRIDES}" == "true" ]]; then
  log "Images: the image_* overrides, as given"
else
  log "Phase 1 - Artifact Registry"
  terraform apply -input=false -auto-approve \
    -target=module.artifact_registry \
    -target=module.registry_secrets \
    -target=google_project_service_identity.artifactregistry \
    -target=google_project_service_identity.run \
    "$@"

  repository="$(terraform output -raw image_repository 2>/dev/null || true)"
  if [[ "${LOCAL_IMAGES:-}" == "1" ]]; then
    command -v docker >/dev/null 2>&1 || die "LOCAL_IMAGES=1 needs docker"
    repository="$(terraform output -raw local_image_repository)"
    log "Pushing the local ${IMAGE_NAMES[*]} :${TAG} to ${repository}"
    gcloud auth configure-docker "${repository%%/*}" --quiet >/dev/null
    for image in "${IMAGE_NAMES[@]}"; do
      docker image inspect "appsec4u/${image}:${TAG}" >/dev/null 2>&1 ||
        die "LOCAL_IMAGES=1 but appsec4u/${image}:${TAG} is not in the local Docker engine"
      docker tag "appsec4u/${image}:${TAG}" "${repository}/${image}:${TAG}"
      docker push -q "${repository}/${image}:${TAG}" >/dev/null
      echo "  ${image}:${TAG} pushed"
    done
  elif [[ -n "${SOURCE}" ]]; then
    repository="$(terraform output -raw local_image_repository)"
    log "Copying ${IMAGE_NAMES[*]} :${TAG} from ${SOURCE} to ${repository}"
    copy_from_source "${repository}"
  else
    log "Resolving ${IMAGE_NAMES[*]} :${TAG} through ${repository}"
  fi

  digests=()
  for image in "${IMAGE_NAMES[@]}"; do
    digest="$(resolve_digest "${repository}" "${image}" "${TAG}" || true)"
    [[ -n "${digest}" ]] || die "could not find ${image}:${TAG} in ${repository}. Check image_tag, and that $([[ -n "${SOURCE}" ]] && echo "the copy from ${SOURCE} succeeded" || echo "dockerhub_username/dockerhub_token are the ones sent with your licence")."
    digests+=("\"${image}\": \"${digest}\"")
    echo "  ${image} ${digest}"
  done
  local_repository=""
  [[ "${LOCAL_IMAGES:-}" == "1" || -n "${SOURCE}" ]] && local_repository="${repository}"
  printf '{\n  "image_repository": "%s",\n  "image_digests": {%s}\n}\n' \
    "${local_repository}" "$(IFS=,; echo "${digests[*]}")" > images.auto.tfvars.json
fi

if [[ "${PLATFORM}" == "gke" ]]; then
  log "Phase 2 - project APIs, network, GKE cluster"
  terraform apply -input=false -auto-approve \
    -target=module.project_services \
    -target=module.network \
    -target=module.gke \
    "$@"

  # On GKE an init container of the web Deployment migrates.
  log "Phase 3 - data services, workloads, load balancer, monitoring"
  terraform apply -input=false -auto-approve "$@"
else
  # Cloud Run: the migration job owns every schema change, and the services
  # refuse to start against an older schema - and Cloud Run waits for a new
  # revision to start. So the job (with the database and everything it needs)
  # is applied first, migrates, and only then do the services roll.
  log "Phase 2 - database, broker, secrets and the migrate job"
  terraform apply -input=false -auto-approve -target='module.cloudrun[0].google_cloud_run_v2_job.migrate' "$@"

  MIGRATE_JOB="$(tf_var var.name_prefix)-migrate"
  tf_var 'jsonencode({ web = local.image_web, worker = local.image_worker, worker_poc = local.image_worker_poc })' \
    > images.current.json
  if [[ "${MIGRATE:-}" != "1" && -f images.migrated.json ]] && cmp -s images.current.json images.migrated.json; then
    log "Images unchanged since their last migration: skipping it, so scans in flight keep running"
  else
    log "Running migrations (${MIGRATE_JOB})"
    gcloud run jobs execute "${MIGRATE_JOB}" --region "${REGION}" --project "${PROJECT}" --wait
    cp images.current.json images.migrated.json
  fi
  rm -f images.current.json

  log "Phase 3 - services, load balancer, monitoring"
  terraform apply -input=false -auto-approve "$@"
fi

log "Done"
terraform output

if [[ "${INTERNAL}" == "true" ]]; then
  third="  3. The url is the web service's Cloud Run address, served only to callers
     inside the VPC and the networks connected to it. See google_apis_range and
     dns_inbound_forwarders_command above for what the corporate network needs."
else
  third="  3. Without a domain_name the certificate is self-signed, so your browser will
     warn once. Set domain_name and re-run for a Google-managed certificate."
fi

cat <<EOF

Next:

  1. Open the url above now. A new installation shows the setup page, where
     the first account - administrator of its team and of the installation -
     is created. Whoever reaches the page first gets that account.
  2. Configure the AI provider on the System AI card under System Settings ->
     Shared services (Vertex AI in this project, or any OpenAI-compatible
     endpoint). With no scanner containers, the model does the analysis, so
     this is not optional.
${third}
  4. This deployment runs static analysis only: there is no Docker daemon for
     the dynamic and infrastructure scanners.

EOF
