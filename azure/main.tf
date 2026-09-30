###############################################################################
# ScanSuite on Azure Container Apps.
#
# Two phases, both driven by deploy.sh:
#   1. deploy_workloads = false  the platform: network, data, vault, registry,
#                                environment, Redis. Needs no licence and no
#                                image.
#   2. deploy_workloads = true   the apps and jobs, once deploy.sh has imported
#                                the images into the registry.
###############################################################################

locals {
  prefix = var.name_prefix
  prod   = var.environment == "prod"

  tags = merge({
    app         = "scansuite"
    environment = var.environment
    managed-by  = "terraform"
  }, var.tags)

  # The PyArmor outer licence. Its bytes go into Key Vault as base64; its file
  # name is plain configuration so the start-up prelude knows what to call it.
  key_dir      = var.key_dir != "" ? var.key_dir : "${path.root}/../key"
  licence_list = [for f in try(fileset(local.key_dir, "*.lic"), []) : f]
  licence_name = var.pyarmor_license_file != "" ? var.pyarmor_license_file : (length(local.licence_list) == 1 ? local.licence_list[0] : "")
  licence_b64  = local.licence_name != "" ? try(filebase64("${local.key_dir}/${local.licence_name}"), "") : ""

  db_admin = "scansuite"
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

# Global names (vault, registry, storage accounts, database server) share one
# random suffix.
resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
}

###############################################################################
# Network and logs
###############################################################################

module "network" {
  source = "./modules/network"

  prefix              = local.prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  vnet_cidr            = var.vnet_cidr
  aca_subnet_cidr      = var.aca_subnet_cidr
  postgres_subnet_cidr = var.postgres_subnet_cidr
  enable_nat_gateway   = var.enable_nat_gateway
}

module "monitoring" {
  source = "./modules/monitoring"

  prefix              = local.prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  daily_quota_gb = var.log_daily_quota_gb
  alert_email    = var.alert_email
}

###############################################################################
# Identity
###############################################################################

module "identity" {
  source = "./modules/identity"

  prefix              = local.prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  resource_group_id   = azurerm_resource_group.this.id
  tags                = local.tags
}

locals {
  principals = {
    app     = module.identity.app.principal_id
    poc     = module.identity.poc.principal_id
    migrate = module.identity.migrate.principal_id
  }
}

###############################################################################
# Secrets
###############################################################################

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "redis" {
  length  = 32
  special = false
}

resource "random_password" "flask_secret_key" {
  length  = 64
  special = false
}

# Wraps team secrets (integration and AI credentials). Losing it makes stored
# team secrets unreadable: Key Vault soft delete and backups protect it.
resource "random_id" "team_wrapping_key" {
  byte_length = 32
}

locals {
  secret_values = merge({
    db-password        = random_password.db.result
    redis-auth         = random_password.redis.result
    flask-secret-key   = random_password.flask_secret_key.result
    team-wrapping-keys = jsonencode({ k1 = random_id.team_wrapping_key.b64_std })
    }, var.deploy_workloads ? {
    pyarmor-license-b64 = local.licence_b64
  } : {})

  secret_names = concat(
    ["db-password", "redis-auth", "flask-secret-key", "team-wrapping-keys"],
    var.deploy_workloads ? ["pyarmor-license-b64"] : [],
  )

  # Per-secret readers. worker-poc (poc) runs model-written code: it reads the
  # database and broker, and the licence its PyArmor-protected image needs -
  # never the Flask secret or the wrapping keys that decrypt team credentials,
  # unless worker_poc_installation_secrets is on for an image whose
  # work_poc.py still demands them.
  poc_if_legacy = var.worker_poc_installation_secrets ? ["poc"] : []
  secret_readers = merge({
    db-password        = ["app", "poc", "migrate"]
    redis-auth         = ["app", "poc", "migrate"]
    flask-secret-key   = concat(["app", "migrate"], local.poc_if_legacy)
    team-wrapping-keys = concat(["app", "migrate"], local.poc_if_legacy)
    }, var.deploy_workloads ? {
    pyarmor-license-b64 = ["app", "poc", "migrate"]
  } : {})
}

module "keyvault" {
  source = "./modules/keyvault"

  prefix              = local.prefix
  suffix              = random_string.suffix.result
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
  tenant_id           = data.azurerm_client_config.current.tenant_id

  operator_principal_id = data.azurerm_client_config.current.object_id
  purge_protection      = local.prod

  secret_names = local.secret_names
  secrets      = local.secret_values
  principals   = local.principals
  readers      = local.secret_readers
}

###############################################################################
# Registry, database, storage
###############################################################################

module "registry" {
  source = "./modules/registry"

  prefix              = local.prefix
  suffix              = random_string.suffix.result
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  sku             = local.prod ? "Premium" : "Basic"
  pull_principals = local.principals
}

module "postgres" {
  source = "./modules/postgres"

  prefix              = local.prefix
  suffix              = random_string.suffix.result
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  vnet_id   = module.network.vnet_id
  subnet_id = module.network.postgres_subnet_id

  sku_name         = var.postgres_sku
  storage_mb       = var.postgres_storage_mb
  highly_available = local.prod

  administrator_login    = local.db_admin
  administrator_password = random_password.db.result
}

module "storage" {
  source = "./modules/storage"

  prefix              = local.prefix
  suffix              = random_string.suffix.result
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  aca_subnet_id       = module.network.aca_subnet_id
  replication_type    = local.prod ? "ZRS" : "LRS"
  retention_days      = var.artifact_retention_days
  writer_principal_id = module.identity.app.principal_id
}

###############################################################################
# Container Apps
###############################################################################

module "environment" {
  source = "./modules/environment"

  prefix              = local.prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  subnet_id                  = module.network.aca_subnet_id
  log_analytics_workspace_id = module.monitoring.workspace_id
  dedicated_scan_profile     = local.prod
}

# Non-secret configuration shared by every workload - the app_config of
# infra/main.tf, with Azure's services in place of Google's.
locals {
  app_config = {
    PS_DATABASE_HOST = module.postgres.fqdn
    PS_DATABASE_PORT = "5432"
    PS_DATABASE_NAME = module.postgres.database_name
    PS_DATABASE_USER = local.db_admin
    PGSSLMODE        = "require"

    CELERY_HOST = "${local.prefix}-redis"
    REDIS_PORT  = "6379"

    AZURE_STORAGE_ACCOUNT_URL = module.storage.artifacts_account_url
    AZURE_STORAGE_CONTAINER   = module.storage.artifacts_container
    STORAGE_PREFIX            = "scansuite"

    EXECUTION_BACKEND   = "aca"
    ACA_SUBSCRIPTION_ID = var.subscription_id
    ACA_RESOURCE_GROUP  = azurerm_resource_group.this.name
    ACA_JOB_NAME        = "${local.prefix}-sast"

    PYARMOR_RKEY             = "/key"
    PYARMOR_LICENSE_FILENAME = local.licence_name

    SCANSUITE_ACTIVE_WRAPPING_KEY = "k1"
    LOG_FILE                      = "/dev/stdout"
    # One proxy in front: Container Apps ingress sets X-Forwarded-For.
    TRUSTED_PROXY_HOPS = "1"

    ENABLE_STATIC_SCANS  = var.enable_static_scans
    ENABLE_DYNAMIC_SCANS = var.enable_dynamic_scans
    TZ                   = var.timezone
  }
}

module "workloads" {
  source = "./modules/workloads"

  prefix              = local.prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  environment_id    = module.environment.id
  scan_profile_name = module.environment.scan_profile_name
  deploy_workloads  = var.deploy_workloads

  registry_server = module.registry.login_server
  image_tag       = var.image_tag
  image_digests   = var.image_digests

  identities = {
    app     = module.identity.app
    poc     = module.identity.poc
    migrate = module.identity.migrate
  }
  dispatcher_role_definition_id = module.identity.dispatcher_role_definition_id

  secret_ids = module.keyvault.secret_ids
  config     = local.app_config

  poc_installation_secrets = var.worker_poc_installation_secrets

  web_allowed_cidrs = var.web_allowed_cidrs
  web_min_replicas  = var.web_min_replicas
  web_max_replicas  = var.web_max_replicas

  scan_cpu             = var.scan_cpu
  scan_memory          = var.scan_memory
  scan_timeout_seconds = var.scan_timeout_seconds

  # Secrets are read by reference and images pulled as the identities, so
  # their grants must exist first; the database must have its parameters.
  depends_on = [module.keyvault, module.registry, module.postgres, module.storage]
}

###############################################################################
# Alerts
###############################################################################

module "alerts" {
  source = "./modules/alerts"
  count  = var.alert_email != "" ? 1 : 0

  prefix              = local.prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  action_group_id    = module.monitoring.action_group_id
  workspace_id       = module.monitoring.workspace_id
  postgres_server_id = module.postgres.server_id
}

###############################################################################
# Checks
###############################################################################

check "licence" {
  assert {
    condition     = !var.deploy_workloads || local.licence_b64 != ""
    error_message = "deploy_workloads needs the PyArmor licence for image tag ${var.image_tag}: put exactly one *.lic in ${local.key_dir} or set pyarmor_license_file. Without it no container starts."
  }
}
