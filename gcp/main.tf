locals {
  prefix = var.name_prefix

  use_cloudrun = var.platform == "cloudrun"
  use_gke      = var.platform == "gke"

  # The llm-scansuite key as base64. Prefer reading it from a file (so the
  # secret value is not pasted into a tfvars file); fall back to the raw var.
  # On GKE this lands in a Kubernetes Secret, so it is in Terraform state either
  # way - keep state local to the in-perimeter host.
  llm_sa_key_b64 = var.llm_sa_key_file != "" ? filebase64(var.llm_sa_key_file) : var.llm_sa_key_b64

  # The PyArmor outer licence sitting in the local key directory. Its bytes go
  # into a secret as base64; its filename is passed as plain config so the
  # decode step knows what to call the file. key.json is deliberately not read
  # from here any more - the application authenticates with the existing
  # llm-scansuit key, supplied as a secret out of band.
  #
  # pyarmor_license_file names the exact licence, because a key directory may
  # hold several (one per image tag) and the chosen one must match the deployed
  # image. It falls back to the single .lic when there is exactly one.
  key_files = { for f in fileset(local.key_dir, "*.lic") : f => filebase64("${local.key_dir}/${f}") }
  pyarmor_licence = (var.pyarmor_license_file != "" ? var.pyarmor_license_file :
  length(local.key_files) == 1 ? keys(local.key_files)[0] : null)
  # Empty when there is no licence to use; terraform_data.licence_required says
  # so in words instead of an indexing error.
  licence_b64 = local.pyarmor_licence == null ? "" : lookup(local.key_files, local.pyarmor_licence, "")

  # Operational secrets, readable by the full-trust workloads AND worker-poc
  # (which needs the database and broker). Mapped env var -> secret id.
  # One database account: every workload connects as the schema owner, which
  # images built from 3b0522c (2026-09-21) on expect; team isolation is the
  # application's job, not a second database role's.
  operational_secret_sources = {
    PS_DATABASE_PASSWORD = "db-password"
    REDIS_PASSWORD       = "redis-auth"
    SECRET_KEY           = "flask-secret-key"
  }

  # The /key material and the secret wrapping keys. Kept in a separate secret
  # set whose only accessor is the app service account, so the worker-poc
  # identity - which runs model-written code - cannot read the licence, the LLM
  # key or the keys that decrypt team and platform secrets, even via its
  # metadata token.
  # The out-of-band LLM key is wired into the workloads only when one is
  # expected: Cloud Run refuses a revision whose secret has no version, and
  # without the key the application uses the workload's own identity anyway.
  # After adding the key's version out of band, re-run deploy.sh.
  llm_key_expected = var.llm_service_account_email != "" || local.llm_sa_key_b64 != ""
  key_secret_sources = merge(
    { SCANSUITE_WRAPPING_KEYS = "team-wrapping-keys" },
    local.llm_key_expected ? { GCP_KEY_JSON_B64 = "llm-sa-key-b64" } : {},
  )

  # The PyArmor licence, on its own: every image is protected and starts only
  # with it - worker-poc's included - so its readers are the three identities.
  licence_secret_sources = {
    PYARMOR_LICENSE_B64 = "pyarmor-license-b64"
  }

  operational_secret_ids = module.secrets.env_secret_ids
  key_secret_ids         = module.key_secrets.env_secret_ids
  licence_secret_ids     = module.licence_secrets.env_secret_ids
  all_secret_ids         = merge(local.operational_secret_ids, local.key_secret_ids, local.licence_secret_ids)

  # Full-trust workloads get everything; entries whose secret was never created
  # (an unconfigured optional integration) are filtered out.
  secret_env = {
    for name, secret in merge(local.operational_secret_sources, local.key_secret_sources, local.licence_secret_sources) :
    name => local.all_secret_ids[secret]
    if contains(keys(local.all_secret_ids), secret)
  }

  # worker-poc runs model-written code: database, broker and the licence its
  # protected image needs - never SECRET_KEY, the wrapping keys or the LLM key.
  secret_env_poc = {
    for name in ["PS_DATABASE_PASSWORD", "REDIS_PASSWORD", "PYARMOR_LICENSE_B64"] :
    name => local.all_secret_ids[merge(local.operational_secret_sources, local.licence_secret_sources)[name]]
    if contains(keys(local.all_secret_ids), merge(local.operational_secret_sources, local.licence_secret_sources)[name])
  }

  labels = {
    app         = "scansuite"
    environment = var.environment
    managed-by  = "terraform"
  }

  key_dir = var.key_dir != "" ? var.key_dir : "${path.root}/../key"

  # Auto-detect the operator's public IP (GKE only) so a first apply from a laptop can
  # reach the control plane without anyone editing a variable file. Built as a
  # comprehension over a count-0-or-1 data source rather than an indexed
  # conditional: both branches of a conditional get evaluated, and [0] against
  # an empty list is an error even on the branch that is not taken.
  operator_cidrs = [for r in data.http.operator_ip : "${chomp(r.response_body)}/32"]
  detected_cidrs = var.master_authorized_cidrs != null ? var.master_authorized_cidrs : local.operator_cidrs
}

# GKE only: Cloud Run has no control plane to allowlist, and an installation
# without internet access cannot make this call.
data "http" "operator_ip" {
  count = local.use_gke && var.master_authorized_cidrs == null ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

###############################################################################
# 1. APIs
###############################################################################

module "project_services" {
  source     = "./modules/project_services"
  project_id = var.project_id
}

###############################################################################
# 2. Network - VPC, private services access, Cloud NAT with static egress IPs
###############################################################################

module "network" {
  source = "./modules/network"

  project_id    = var.project_id
  region        = var.region
  prefix        = local.prefix
  subnet_cidr   = var.subnet_cidr
  pods_cidr     = var.pods_cidr
  services_cidr = var.services_cidr
  nat_ip_count  = var.nat_ip_count
  psa_cidr      = var.psa_cidr
  gke           = local.use_gke

  egress_mode            = var.egress_mode
  google_apis_vip        = var.google_apis_vip
  dns_forwarding_zones   = var.dns_forwarding_zones
  dns_inbound_forwarding = var.dns_inbound_forwarding

  depends_on = [module.project_services]
}

###############################################################################
# 3. Optional Cloud KMS key for application-layer Secret encryption in etcd
###############################################################################

module "kms" {
  source = "./modules/kms"
  count  = var.enable_secrets_encryption && local.use_gke ? 1 : 0

  project_id     = var.project_id
  project_number = data.google_project.this.number
  region         = var.region
  prefix         = local.prefix

  depends_on = [module.project_services]
}

###############################################################################
# 4. GKE
###############################################################################

module "gke" {
  source = "./modules/gke"
  count  = local.use_gke ? 1 : 0

  project_id   = var.project_id
  region       = var.region
  zones        = var.zones
  primary_zone = var.primary_zone
  prefix       = local.prefix
  labels       = local.labels

  network_name   = module.network.network_name
  subnet_name    = module.network.subnet_name
  pods_range     = module.network.pods_range_name
  services_range = module.network.services_range_name
  master_cidr    = var.master_cidr

  master_authorized_cidrs = local.detected_cidrs
  deletion_protection     = var.deletion_protection

  general_machine_type     = var.general_machine_type
  scan_engine_machine_type = var.scan_engine_machine_type
  poc_machine_type         = var.poc_machine_type

  database_encryption_key = one(module.kms[*].crypto_key_id)

  depends_on = [module.project_services, module.network]
}

###############################################################################
# 5. Data services
###############################################################################

resource "random_password" "db" {
  length  = 32
  special = false
}

# Wraps team secrets (integration and AI credentials). Losing it makes stored
# team secrets unreadable: Secret Manager keeps its versions, back it up too.
resource "random_id" "team_wrapping_key" {
  byte_length = 32
}

# The uptime check's pass through Cloud Armor (see modules/lb).
resource "random_password" "uptime_token" {
  length  = 32
  special = false
}

resource "random_password" "flask_secret_key" {
  length  = 64
  special = false
}

module "cloudsql" {
  source = "./modules/cloudsql"

  project_id          = var.project_id
  name                = var.cloudsql_name
  region              = var.region
  prefix              = local.prefix
  labels              = local.labels
  network_id          = module.network.network_id
  tier                = var.cloudsql_tier
  disk_gb             = var.cloudsql_disk_gb
  highly_available    = var.cloudsql_ha
  deletion_protection = var.deletion_protection
  db_password         = random_password.db.result

  depends_on = [module.network]
}

module "memorystore" {
  source = "./modules/memorystore"

  project_id       = var.project_id
  region           = var.region
  primary_zone     = var.primary_zone
  prefix           = local.prefix
  labels           = local.labels
  network_id       = module.network.network_id
  memory_gb        = var.redis_memory_gb
  highly_available = var.redis_ha
  tls              = var.redis_tls

  depends_on = [module.network]
}

module "storage" {
  source = "./modules/storage"

  project_id     = var.project_id
  region         = var.region
  prefix         = local.prefix
  labels         = local.labels
  retention_days = var.artifact_retention_days
  force_destroy  = var.artifact_bucket_force_destroy

  depends_on = [module.project_services]
}

# Non-secret configuration shared by every workload on either platform.
# LOG_FILE is the one that earns its keep: logging.basicConfig writes to a
# file, so pointing that file at stdout puts application logs into Cloud
# Logging with no code change.
locals {
  app_config = {
    PS_DATABASE_HOST = module.cloudsql.private_ip
    PS_DATABASE_PORT = "5432"
    PS_DATABASE_NAME = module.cloudsql.database_name
    PS_DATABASE_USER = module.cloudsql.user_name

    SCANSUITE_ACTIVE_WRAPPING_KEY = "k1"

    CELERY_HOST = module.memorystore.host
    REDIS_PORT  = tostring(module.memorystore.port)
    REDIS_TLS   = var.redis_tls ? "true" : "false"
    # Memorystore signs its server certificate with its own CA. The PEM is
    # public; the start-up step writes it to REDIS_CA_CERTS.
    REDIS_CA_PEM   = module.memorystore.ca_certificate
    REDIS_CA_CERTS = var.redis_tls ? "/tmp/redis-ca.pem" : ""

    GCP_STORAGE_BUCKET           = module.storage.artifact_bucket_name
    GCP_STORAGE_PROJECT          = var.project_id
    GCP_STORAGE_PREFIX           = "scansuite"
    GCP_STORAGE_CREDENTIALS_PATH = "/key/key.json"

    # The decode step writes the licence into /key and the image looks for it
    # there; the filename must match what the licence was built as.
    PYARMOR_RKEY             = "/key"
    PYARMOR_LICENSE_FILENAME = local.pyarmor_licence

    LOG_FILE = "/dev/stdout"

    ENABLE_STATIC_SCANS  = var.enable_static_scans
    ENABLE_DYNAMIC_SCANS = var.enable_dynamic_scans

    TZ = var.timezone
  }
}

###############################################################################
# 6. Identity - three Google service accounts (app, poc, migrate)
###############################################################################

module "iam" {
  source = "./modules/iam"

  project_id      = var.project_id
  prefix          = local.prefix
  namespace       = "scansuite"
  artifact_bucket = module.storage.artifact_bucket_name

  llm_service_account_email = var.llm_service_account_email
  enable_workload_identity  = local.use_gke

  depends_on = [module.project_services, module.storage]
}

module "artifact_registry" {
  source = "./modules/artifact_registry"

  project_id = var.project_id
  region     = var.region
  prefix     = local.prefix
  labels     = local.labels

  # The app/poc identities read images; on Cloud Run the Cloud Run Service Agent
  # is what actually pulls, so it needs reader too - locked-down orgs do not
  # always auto-grant it. On GKE the nodes pull as their node SA (already an
  # artifactregistry.reader).
  reader_members = concat(
    [
      "serviceAccount:${module.iam.app_service_account_email}",
      "serviceAccount:${module.iam.poc_service_account_email}",
    ],
    local.use_cloudrun ? [
      "serviceAccount:service-${data.google_project.this.number}@serverless-robot-prod.iam.gserviceaccount.com",
    ] : [],
  )

  # No remote repository when the images are copied from source_registry: it
  # would only point at Docker Hub.
  dockerhub_remote               = var.source_registry == ""
  dockerhub_username             = var.dockerhub_username
  dockerhub_token_secret_version = lookup(module.registry_secrets.version_names, "dockerhub-token", "")

  # The Cloud Run service agent is granted read access here, so it has to exist.
  depends_on = [module.project_services, google_project_service_identity.run]
}

# The Cloud Run service agent pulls the images. Created explicitly: in a new
# project it does not exist until something asks for it, and granting a member
# that does not exist fails ("Service account ... does not exist").
resource "google_project_service_identity" "run" {
  provider = google-beta
  count    = local.use_cloudrun ? 1 : 0

  project = var.project_id
  service = "run.googleapis.com"

  depends_on = [module.project_services]
}

# The Artifact Registry service agent reads the Docker Hub token for the remote
# repository. Created explicitly: it only appears on its own after the first
# repository operation, and the secret grant below needs it now.
resource "google_project_service_identity" "artifactregistry" {
  provider = google-beta

  project = var.project_id
  service = "artifactregistry.googleapis.com"

  depends_on = [module.project_services]
}

# The Docker Hub token, readable by the registry's service agent alone. It used
# to sit in the operational set, where every workload - worker-poc included -
# could read it.
module "registry_secrets" {
  source = "./modules/secrets"

  project_id = var.project_id
  prefix     = local.prefix
  labels     = local.labels

  accessor_members = [
    # Built from the project number so the grant key is known while planning.
    "serviceAccount:service-${data.google_project.this.number}@gcp-sa-artifactregistry.iam.gserviceaccount.com",
  ]

  optional_values = {
    dockerhub-token = var.dockerhub_token
  }

  # The service agent must exist before it is granted access.
  depends_on = [module.project_services, google_project_service_identity.artifactregistry]
}

moved {
  from = module.secrets.google_secret_manager_secret.this["dockerhub-token"]
  to   = module.registry_secrets.google_secret_manager_secret.this["dockerhub-token"]
}

moved {
  from = module.secrets.google_secret_manager_secret_version.this["dockerhub-token"]
  to   = module.registry_secrets.google_secret_manager_secret_version.this["dockerhub-token"]
}

# The three images. By default they are read through the remote repository in
# front of Docker Hub; with source_registry, from the copies deploy.sh made in
# the project's own repository. Either way pinned to the digests deploy.sh
# resolved for image_tag. image_* overrides are used verbatim.
locals {
  image_repository = (var.image_repository != "" ? var.image_repository :
    var.source_registry != "" ? module.artifact_registry.repository_url :
  "${module.artifact_registry.remote_repository_url}/${var.image_source}")

  derived_images = {
    for name in ["teams-web", "teams-worker", "teams-worker-poc"] :
    name => (contains(keys(var.image_digests), name) ?
      "${local.image_repository}/${name}@${var.image_digests[name]}" :
    "${local.image_repository}/${name}:${var.image_tag}")
  }

  image_web        = var.image_web != "" ? var.image_web : local.derived_images["teams-web"]
  image_worker     = var.image_worker != "" ? var.image_worker : local.derived_images["teams-worker"]
  image_worker_poc = var.image_worker_poc != "" ? var.image_worker_poc : local.derived_images["teams-worker-poc"]
}

resource "terraform_data" "licence_required" {
  lifecycle {
    precondition {
      condition     = local.licence_b64 != ""
      error_message = "No licence to deploy with: put exactly one <name>_<code>.lic in ${local.key_dir}, or name the one to use in pyarmor_license_file. The images do not start without it."
    }
  }
}

# The internal installation (no internet route, images copied from an internal
# registry) is built and tested for Cloud Run only.
resource "terraform_data" "internal_installation_on_cloud_run" {
  lifecycle {
    precondition {
      condition     = local.use_cloudrun || (var.egress_mode == "nat" && var.source_registry == "")
      error_message = "egress_mode = \"none\" and source_registry are supported on platform = \"cloudrun\" only."
    }
  }
}

resource "terraform_data" "image_tag_required" {
  lifecycle {
    precondition {
      condition     = var.image_tag != "" || (var.image_web != "" && var.image_worker != "" && var.image_worker_poc != "")
      error_message = "Set image_tag to your licence code (the <code> of key/<name>_<code>.lic), or set all three image_* overrides."
    }
  }
}

###############################################################################
# 7. Secret Manager - the canonical, auditable copy of every credential
###############################################################################

# Operational secrets. Both service accounts can read these - worker-poc needs
# the database and broker.
module "secrets" {
  source = "./modules/secrets"

  project_id = var.project_id
  prefix     = local.prefix
  labels     = local.labels

  accessor_members = [
    "serviceAccount:${module.iam.app_service_account_email}",
    "serviceAccount:${module.iam.poc_service_account_email}",
    "serviceAccount:${module.iam.migrate_service_account_email}",
  ]

  values = {
    db-password      = random_password.db.result
    redis-auth       = module.memorystore.auth_string
    flask-secret-key = random_password.flask_secret_key.result
  }

  depends_on = [module.project_services]
}

# The schema owner's password was readable by the migration job alone while
# web and workers used a second, restricted role. That role is gone (one
# database account), so the secret returns to the operational set; the moves
# keep the existing secret and its versions.
moved {
  from = module.migration_secrets.google_secret_manager_secret.this["db-password"]
  to   = module.secrets.google_secret_manager_secret.this["db-password"]
}

moved {
  from = module.migration_secrets.google_secret_manager_secret_version.this["db-password"]
  to   = module.secrets.google_secret_manager_secret_version.this["db-password"]
}

# The /key material, injected as base64 env at container start. Only the app
# service account can read these, so the model-code sandbox (worker-poc) cannot
# reach the licence or the LLM key even with its own metadata token.
#
#   pyarmor-license-b64  the outer licence from the local key directory.
#   llm-sa-key-b64       the existing llm-scansuit key JSON. Supplied out of
#                        band (empty here keeps it out of Terraform state); the
#                        container is always created so the workloads can
#                        reference it and a version can be added after apply.
module "key_secrets" {
  source = "./modules/secrets"

  project_id = var.project_id
  prefix     = local.prefix
  labels     = local.labels

  accessor_members = [
    "serviceAccount:${module.iam.app_service_account_email}",
    "serviceAccount:${module.iam.migrate_service_account_email}",
  ]

  values = {
    team-wrapping-keys = jsonencode({ k1 = random_id.team_wrapping_key.b64_std })
  }

  deferred_values = {
    llm-sa-key-b64 = local.llm_sa_key_b64
  }

  depends_on = [module.project_services]
}

# The licence opens the protected code and nothing else, so worker-poc may read
# it; its image does not start without it.
module "licence_secrets" {
  source = "./modules/secrets"

  project_id = var.project_id
  prefix     = local.prefix
  labels     = local.labels

  accessor_members = [
    "serviceAccount:${module.iam.app_service_account_email}",
    "serviceAccount:${module.iam.migrate_service_account_email}",
    "serviceAccount:${module.iam.poc_service_account_email}",
  ]

  values = {
    pyarmor-license-b64 = local.licence_b64
  }

  depends_on = [module.project_services]
}

moved {
  from = module.key_secrets.google_secret_manager_secret.this["pyarmor-license-b64"]
  to   = module.licence_secrets.google_secret_manager_secret.this["pyarmor-license-b64"]
}

moved {
  from = module.key_secrets.google_secret_manager_secret_version.this["pyarmor-license-b64"]
  to   = module.licence_secrets.google_secret_manager_secret_version.this["pyarmor-license-b64"]
}

###############################################################################
# 8. Kubernetes workloads
###############################################################################

module "kubernetes" {
  source = "./modules/kubernetes"
  count  = local.use_gke ? 1 : 0

  prefix     = local.prefix
  namespace  = "scansuite"
  project_id = var.project_id

  app_service_account_email = module.iam.app_service_account_email
  poc_service_account_email = module.iam.poc_service_account_email

  image_web        = local.image_web
  image_worker     = local.image_worker
  image_worker_poc = local.image_worker_poc

  dockerhub_username  = var.dockerhub_username
  dockerhub_token     = var.dockerhub_token
  image_pull_registry = var.image_pull_registry

  db_host     = module.cloudsql.private_ip
  db_name     = module.cloudsql.database_name
  db_user     = module.cloudsql.user_name
  db_password = random_password.db.result

  team_wrapping_keys = jsonencode({ k1 = random_id.team_wrapping_key.b64_std })

  redis_host     = module.memorystore.host
  redis_password = module.memorystore.auth_string
  redis_config   = { for k in ["REDIS_PORT", "REDIS_TLS", "REDIS_CA_PEM", "REDIS_CA_CERTS"] : k => local.app_config[k] }

  artifact_bucket = module.storage.artifact_bucket_name

  flask_secret_key = random_password.flask_secret_key.result

  # /key files injected as base64 env, decoded at container start - matching the
  # Cloud Run path. worker-poc never receives these.
  pyarmor_license_b64      = local.licence_b64
  pyarmor_licence_filename = local.pyarmor_licence
  llm_sa_key_b64           = local.llm_sa_key_b64

  timezone             = var.timezone
  enable_static_scans  = var.enable_static_scans
  enable_dynamic_scans = var.enable_dynamic_scans

  worker_replicas = var.worker_replicas
  poc_replicas    = var.poc_replicas
  scratch_disk_gb = var.scratch_disk_gb

  depends_on = [module.gke, module.cloudsql, module.memorystore, module.storage, module.iam, module.licence_secrets]
}

# The NEG controller creates the zonal network endpoint groups a few seconds
# after the Services exist. The load balancer reads them as data sources, so
# give the controller a head start rather than failing the first apply.
resource "time_sleep" "wait_for_negs" {
  count = local.use_gke ? 1 : 0

  depends_on      = [module.kubernetes]
  create_duration = "150s"
}

###############################################################################
# 9. Cloud Run workloads (platform = cloudrun)
###############################################################################

module "cloudrun" {
  source = "./modules/cloudrun"
  count  = local.use_cloudrun ? 1 : 0

  project_id = var.project_id
  region     = var.region
  prefix     = local.prefix
  labels     = local.labels

  network_name = module.network.network_name
  subnet_name  = module.network.subnet_name

  app_service_account_email     = module.iam.app_service_account_email
  poc_service_account_email     = module.iam.poc_service_account_email
  migrate_service_account_email = module.iam.migrate_service_account_email

  image_web        = local.image_web
  image_worker     = local.image_worker
  image_worker_poc = local.image_worker_poc

  config         = local.app_config
  secret_env     = local.secret_env
  secret_env_poc = local.secret_env_poc

  internal_only = var.internal_only

  admin_instances           = var.admin_instances
  poc_instances             = var.poc_replicas
  web_min_instances         = var.web_min_instances
  web_max_instances         = var.web_max_instances
  scan_task_timeout_seconds = var.scan_task_timeout_seconds
  scan_cpu                  = var.scan_cpu
  scan_memory               = var.scan_memory
  deletion_protection       = var.deletion_protection

  depends_on = [module.cloudsql, module.memorystore, module.storage, module.iam, module.secrets, module.key_secrets, module.licence_secrets]
}

###############################################################################
# 10. Load balancer - replaces nginx
###############################################################################

# No external front door when internal_only: the Cloud Run service is set to
# internal ingress and reached over the VPC / corporate network directly.
module "lb" {
  source = "./modules/lb"
  count  = var.internal_only ? 0 : 1

  project_id = var.project_id
  region     = var.region
  zones      = var.zones
  prefix     = local.prefix

  backend_mode      = var.platform
  web_neg_name      = local.use_gke ? module.kubernetes[0].web_neg_name : ""
  cloud_run_service = local.use_cloudrun ? module.cloudrun[0].web_service_name : ""

  domain_name = var.domain_name
  manage_dns  = var.manage_dns

  web_allowed_cidrs = var.web_allowed_cidrs
  uptime_token      = random_password.uptime_token.result

  depends_on = [time_sleep.wait_for_negs, module.cloudrun]
}

###############################################################################
# 11. Observability
###############################################################################

module "observability" {
  source = "./modules/observability"

  project_id        = var.project_id
  prefix            = local.prefix
  alert_email       = var.alert_email
  uptime_token      = random_password.uptime_token.result
  lb_ip             = one(module.lb[*].ip_address)
  domain_name       = var.domain_name
  cloudsql_instance = module.cloudsql.instance_name
  platform          = var.platform
  internal_only     = var.internal_only

  depends_on = [module.lb]
}
