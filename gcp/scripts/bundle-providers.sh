#!/usr/bin/env bash
#
# Pack the Terraform providers this configuration needs, for a deploy host that
# cannot reach registry.terraform.io (an installation without internet access).
#
# On a machine with internet access, from infra/:
#
#   ./scripts/bundle-providers.sh [platform]      # default linux_amd64
#
# It writes terraform-providers.tar.gz. Copy it to the deploy host, unpack it
# next to infra/ and point Terraform at it before deploy.sh:
#
#   tar -xzf terraform-providers.tar.gz          # creates terraform-providers/
#   sed -i "s#TERRAFORM_PROVIDERS_DIR#$PWD/terraform-providers#" terraform-providers/terraformrc
#   export TF_CLI_CONFIG_FILE="$PWD/terraform-providers/terraformrc"
#
# terraform init then installs from the bundle and never contacts the registry.

set -euo pipefail

cd "$(dirname "$0")/.."

PLATFORM="${1:-linux_amd64}"
OUT="terraform-providers"

command -v terraform >/dev/null || { echo "terraform is required" >&2; exit 1; }

rm -rf "${OUT}" && mkdir -p "${OUT}/mirror"
terraform providers mirror -platform="${PLATFORM}" "${OUT}/mirror"

# The path is resolved on the deploy host: the config sits inside the bundle.
cat > "${OUT}/terraformrc" <<'EOF'
provider_installation {
  filesystem_mirror {
    path    = "TERRAFORM_PROVIDERS_DIR/mirror"
    include = ["registry.terraform.io/*/*"]
  }
  direct {
    exclude = ["registry.terraform.io/*/*"]
  }
}
EOF
cat > "${OUT}/README" <<'EOF'
Unpack next to infra/, then:

  sed -i "s#TERRAFORM_PROVIDERS_DIR#$PWD/terraform-providers#" terraform-providers/terraformrc
  export TF_CLI_CONFIG_FILE="$PWD/terraform-providers/terraformrc"
EOF

tar -czf terraform-providers.tar.gz "${OUT}"
rm -rf "${OUT}"
echo "Wrote terraform-providers.tar.gz (${PLATFORM})."
