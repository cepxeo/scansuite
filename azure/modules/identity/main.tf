###############################################################################
# Three user-assigned identities, the same split as infra/modules/iam:
#
#   app      web, workers, celery-beat and the scan job. Reads every secret,
#            writes artifacts, starts scan executions.
#   poc      worker-poc. It runs model-written exploit code, so it reads the
#            database and broker secrets and the licence its protected image
#            needs - not the Flask secret or the wrapping keys (unless
#            worker_poc_installation_secrets is on for an older image) - and
#            holds no storage role and no job permissions.
#   migrate  the migrate job. Database, licence and wrapping keys; no storage.
#
# All three pull images from the registry (AcrPull, in the registry module).
###############################################################################

resource "azurerm_user_assigned_identity" "app" {
  name                = "${var.prefix}-id-app"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "poc" {
  name                = "${var.prefix}-id-poc"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "migrate" {
  name                = "${var.prefix}-id-migrate"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

###############################################################################
# The scan dispatcher role
#
# Not the built-in Container Apps Jobs Operator: its Microsoft.App/jobs/*/action
# wildcard includes listSecrets. These are exactly the calls
# worker/execution/aca.py makes. Starting a job can override its command, so
# holding this role is as powerful as the job's own identity - it is assigned
# to the app identity only, at the scan job's scope (containerapps module).
###############################################################################

resource "azurerm_role_definition" "dispatcher" {
  name        = "${var.prefix} scan job dispatcher (${var.resource_group_name})"
  scope       = var.resource_group_id
  description = "Start, read and stop executions of the ScanSuite scan job."

  permissions {
    actions = [
      "Microsoft.App/jobs/read",
      "Microsoft.App/jobs/start/action",
      "Microsoft.App/jobs/stop/action",
      "Microsoft.App/jobs/stop/execution/action",
      "Microsoft.App/jobs/executions/read",
      "Microsoft.App/jobs/execution/read",
    ]
  }

  assignable_scopes = [var.resource_group_id]
}
