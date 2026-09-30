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

if [[ -z "$(terraform state list 2>/dev/null)" ]]; then
  echo "No Terraform state here - nothing to destroy." >&2
  exit 1
fi
# A destroy that stopped part-way has already dropped the outputs from the
# state, so fall back to the configured name: re-running must finish the job.
RG="$(terraform output -raw resource_group 2>/dev/null || true)"
if [[ -z "${RG}" ]]; then
  RG="$(terraform console -input=false <<<'var.resource_group_name' 2>/dev/null | tr -d '"\r' || true)"
fi
[[ -n "${RG}" ]] || { echo "Could not tell which resource group this state belongs to." >&2; exit 1; }

if [[ "${1:-}" != "-y" ]]; then
  read -r -p "Destroy everything in ${RG}, including the database? Type the resource group name: " answer
  [[ "${answer}" == "${RG}" ]] || { echo "Not confirmed." >&2; exit 1; }
else
  shift
fi

terraform destroy -input=false -auto-approve "$@"
