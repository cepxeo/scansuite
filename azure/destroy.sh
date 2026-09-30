#!/usr/bin/env bash
#
# Tear the deployment down. Everything lives in one resource group, plus the
# environment's managed "<rg>-aca-managed" group that Azure removes with it.
#
# In dev the provider purges the soft-deleted Key Vault on destroy, so the
# names can be reused; in prod (purge protection) the vault stays recoverable
# for its retention period. Pass -y to skip the confirmation.
set -euo pipefail

cd "$(dirname "$0")"

RG="$(terraform output -raw resource_group 2>/dev/null || true)"
[[ -n "${RG}" ]] || { echo "No Terraform state here - nothing to destroy." >&2; exit 1; }

if [[ "${1:-}" != "-y" ]]; then
  read -r -p "Destroy everything in ${RG}, including the database? Type the resource group name: " answer
  [[ "${answer}" == "${RG}" ]] || { echo "Not confirmed." >&2; exit 1; }
else
  shift
fi

terraform destroy -input=false -auto-approve "$@"
