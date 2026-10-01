#!/usr/bin/env bash
#
# Copy the three ScanSuite images from Docker Hub into this project's standard
# Artifact Registry repository by hand.
#
# Usually not needed: deploy.sh reads the images through the remote repository
# in front of Docker Hub, or pushes a local build with LOCAL_IMAGES=1. Use this
# where the deployment must not reach Docker Hub at all, then point the image_*
# overrides at the copies.
#
# Usage:
#   ./scripts/mirror-images.sh <project-id> <licence code> [region] [repository]
#
# Needs docker, signed in to Docker Hub with the user sent with your licence.

set -euo pipefail

PROJECT="${1:?usage: mirror-images.sh <project-id> <licence code> [region] [repository]}"
TAG="${2:?usage: mirror-images.sh <project-id> <licence code> [region] [repository]}"
REGION="${3:-europe-west3}"
REPOSITORY="${4:-scansuite}"

REPO="${REGION}-docker.pkg.dev/${PROJECT}/${REPOSITORY}"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
command -v gcloud >/dev/null || { echo "gcloud is required" >&2; exit 1; }

echo "==> Authenticating docker against ${REGION}-docker.pkg.dev"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

for image in teams-web teams-worker teams-worker-poc; do
  echo "==> appsec4u/${image}:${TAG}  ->  ${REPO}/${image}:${TAG}"
  docker pull "appsec4u/${image}:${TAG}"
  docker tag "appsec4u/${image}:${TAG}" "${REPO}/${image}:${TAG}"
  docker push "${REPO}/${image}:${TAG}"
done

cat <<EOF

Mirrored into ${REPO}. Add to terraform.tfvars:

  image_web        = "${REPO}/teams-web:${TAG}"
  image_worker     = "${REPO}/teams-worker:${TAG}"
  image_worker_poc = "${REPO}/teams-worker-poc:${TAG}"

EOF
