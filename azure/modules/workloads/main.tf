###############################################################################
# Everything that runs in the Container Apps environment.
#
#   redis         Celery broker and result backend (dev). Internal TCP ingress,
#                 AUTH from Key Vault, noeviction. Part of the platform: it is
#                 created even when deploy_workloads is off.
#   web           Container App, external ingress on 5000, IP allowlist.
#   worker-admin  queue "admin".
#   celery-beat   exactly one replica, always: two double every schedule.
#   worker-poc    queue "poc", its own identity: database, broker and licence
#                 only, no storage or job roles; scales 0-1 on the queue.
#   sast          Manual job, one execution per scan, started by
#                 worker/execution/aca.py with SCAN_ID. Scratch on NFS.
#   migrate       Manual job, run by deploy.sh after every apply.
#
# The /key material (PyArmor licence) arrives as a base64 secret env var and
# the same shell prelude as infra/modules/cloudrun decodes it before the real
# command runs, so both clouds behave identically.
###############################################################################

locals {
  # Decodes into $PYARMOR_RKEY (/key by default), where PyArmor looks. The PoC
  # image runs as uid 10001 and cannot create /key, so it points PYARMOR_RKEY
  # into its own home.
  key_bootstrap = <<-EOT
    set -e
    key_dir="$${PYARMOR_RKEY:-/key}"
    mkdir -p "$key_dir"
    if [ -n "$PYARMOR_LICENSE_B64" ] && [ -n "$PYARMOR_LICENSE_FILENAME" ] && [ ! -f "$key_dir/$PYARMOR_LICENSE_FILENAME" ]; then
      printf %s "$PYARMOR_LICENSE_B64" | base64 -d > "$key_dir/$PYARMOR_LICENSE_FILENAME"
      chmod 0400 "$key_dir/$PYARMOR_LICENSE_FILENAME"
    fi
  EOT

  # sh -lc 'prelude; exec "$0" "$@"' python app.py  ->  $0=python, $@=app.py.
  sh_prefix = ["/bin/sh", "-lc", "${local.key_bootstrap}\nexec \"$0\" \"$@\""]

  # Environment variable -> Key Vault secret, by trust level.
  secret_env_full = {
    PS_DATABASE_PASSWORD    = "db-password"
    REDIS_PASSWORD          = "redis-auth"
    SECRET_KEY              = "flask-secret-key"
    SCANSUITE_WRAPPING_KEYS = "team-wrapping-keys"
    PYARMOR_LICENSE_B64     = "pyarmor-license-b64"
  }
  # worker-poc runs model-written code: database, broker, and the licence its
  # PyArmor-protected image needs. SECRET_KEY and the wrapping keys only for an
  # image whose work_poc.py still calls ensure_secrets() and so refuses to
  # start without them (poc_installation_secrets).
  secret_env_poc = merge({
    PS_DATABASE_PASSWORD = "db-password"
    REDIS_PASSWORD       = "redis-auth"
    PYARMOR_LICENSE_B64  = "pyarmor-license-b64"
    }, var.poc_installation_secrets ? {
    SECRET_KEY              = "flask-secret-key"
    SCANSUITE_WRAPPING_KEYS = "team-wrapping-keys"
  } : {})

  env_app     = merge(var.config, { AZURE_CLIENT_ID = var.identities.app.client_id })
  env_migrate = merge(var.config, { AZURE_CLIENT_ID = var.identities.migrate.client_id })
  env_poc = merge(var.config, {
    AZURE_CLIENT_ID = var.identities.poc.client_id
    PYARMOR_RKEY    = "/work/key"
  })

  redis_name = "${var.prefix}-redis"
  # By digest when deploy.sh supplied one: release tags are reused for every
  # build of a licence, so a tag alone would neither create new revisions nor
  # make nodes that cached the tag pull the new image.
  images = {
    web    = contains(keys(var.image_digests), "teams-web") ? "${var.registry_server}/teams-web@${var.image_digests["teams-web"]}" : "${var.registry_server}/teams-web:${var.image_tag}"
    worker = contains(keys(var.image_digests), "teams-worker") ? "${var.registry_server}/teams-worker@${var.image_digests["teams-worker"]}" : "${var.registry_server}/teams-worker:${var.image_tag}"
    poc    = contains(keys(var.image_digests), "teams-worker-poc") ? "${var.registry_server}/teams-worker-poc@${var.image_digests["teams-worker-poc"]}" : "${var.registry_server}/teams-worker-poc:${var.image_tag}"
  }
  workloads = var.deploy_workloads ? 1 : 0
}

###############################################################################
# Redis (dev)
###############################################################################

resource "azurerm_container_app" "redis" {
  name                         = local.redis_name
  container_app_environment_id = var.environment_id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identities.app.id]
  }

  secret {
    name                = "redis-auth"
    key_vault_secret_id = var.secret_ids["redis-auth"]
    identity            = var.identities.app.id
  }

  ingress {
    external_enabled = false
    transport        = "tcp"
    target_port      = 6379
    exposed_port     = 6379

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name    = "redis"
      image   = "docker.io/library/redis:7.2-alpine"
      cpu     = 0.25
      memory  = "0.5Gi"
      command = ["/bin/sh", "-c"]
      # The broker holds queued work: never evict. No persistence in dev; a
      # restart loses queued admin tasks, which beat re-issues on schedule.
      args = ["exec redis-server --requirepass \"$REDIS_PASSWORD\" --maxmemory-policy noeviction --save '' --appendonly no"]

      env {
        name        = "REDIS_PASSWORD"
        secret_name = "redis-auth"
      }

      liveness_probe {
        transport = "TCP"
        port      = 6379
      }
    }
  }
}

###############################################################################
# Web
###############################################################################

resource "azurerm_container_app" "web" {
  count = local.workloads

  name                         = "${var.prefix}-web"
  container_app_environment_id = var.environment_id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identities.app.id]
  }

  registry {
    server   = var.registry_server
    identity = var.identities.app.id
  }

  dynamic "secret" {
    for_each = toset(values(local.secret_env_full))
    content {
      name                = secret.value
      key_vault_secret_id = var.secret_ids[secret.value]
      identity            = var.identities.app.id
    }
  }

  ingress {
    external_enabled           = true
    target_port                = 5000
    transport                  = "http"
    allow_insecure_connections = false

    dynamic "ip_security_restriction" {
      for_each = var.web_allowed_cidrs
      content {
        name             = "allow-${ip_security_restriction.key}"
        action           = "Allow"
        ip_address_range = ip_security_restriction.value
      }
    }

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.web_min_replicas
    max_replicas = var.web_max_replicas

    container {
      name    = "web"
      image   = local.images.web
      cpu     = 1
      memory  = "2Gi"
      command = concat(local.sh_prefix, ["python", "app.py"])

      dynamic "env" {
        for_each = local.env_app
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.secret_env_full
        content {
          name        = env.key
          secret_name = env.value
        }
      }

      # Flask start plus a database connection; migrations live in the job.
      startup_probe {
        transport               = "TCP"
        port                    = 5000
        initial_delay           = 10
        interval_seconds        = 10
        failure_count_threshold = 10
        timeout                 = 5
      }

      liveness_probe {
        transport = "TCP"
        port      = 5000
      }
    }
  }
}

###############################################################################
# Workers
###############################################################################

resource "azurerm_container_app" "worker_admin" {
  count = local.workloads

  name                         = "${var.prefix}-worker-admin"
  container_app_environment_id = var.environment_id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identities.app.id]
  }

  registry {
    server   = var.registry_server
    identity = var.identities.app.id
  }

  dynamic "secret" {
    for_each = toset(values(local.secret_env_full))
    content {
      name                = secret.value
      key_vault_secret_id = var.secret_ids[secret.value]
      identity            = var.identities.app.id
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name    = "worker-admin"
      image   = local.images.worker
      cpu     = 0.5
      memory  = "1Gi"
      command = concat(local.sh_prefix, ["python", "work_admin.py"])

      dynamic "env" {
        for_each = local.env_app
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.secret_env_full
        content {
          name        = env.key
          secret_name = env.value
        }
      }
    }
  }
}

resource "azurerm_container_app" "beat" {
  count = local.workloads

  name                         = "${var.prefix}-celery-beat"
  container_app_environment_id = var.environment_id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identities.app.id]
  }

  registry {
    server   = var.registry_server
    identity = var.identities.app.id
  }

  dynamic "secret" {
    for_each = toset(values(local.secret_env_full))
    content {
      name                = secret.value
      key_vault_secret_id = var.secret_ids[secret.value]
      identity            = var.identities.app.id
    }
  }

  template {
    # Exactly one, always. Two beat instances double every scheduled scan.
    min_replicas = 1
    max_replicas = 1

    container {
      name    = "celery-beat"
      image   = local.images.worker
      cpu     = 0.25
      memory  = "0.5Gi"
      command = concat(local.sh_prefix, ["/app/run_beat"])

      dynamic "env" {
        for_each = local.env_app
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.secret_env_full
        content {
          name        = env.key
          secret_name = env.value
        }
      }
    }
  }
}

resource "azurerm_container_app" "worker_poc" {
  count = local.workloads

  name                         = "${var.prefix}-worker-poc"
  container_app_environment_id = var.environment_id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  # Its own identity: this container executes model-generated exploit code.
  # Database, broker and licence (see secret_env_poc); no storage role and no
  # job permissions.
  identity {
    type         = "UserAssigned"
    identity_ids = [var.identities.poc.id]
  }

  registry {
    server   = var.registry_server
    identity = var.identities.poc.id
  }

  dynamic "secret" {
    for_each = toset(values(local.secret_env_poc))
    content {
      name                = secret.value
      key_vault_secret_id = var.secret_ids[secret.value]
      identity            = var.identities.poc.id
    }
  }

  template {
    min_replicas = 0
    max_replicas = 1

    container {
      name    = "worker-poc"
      image   = local.images.poc
      cpu     = 0.5
      memory  = "1Gi"
      command = concat(local.sh_prefix, ["python", "/app/work_poc.py"])

      dynamic "env" {
        for_each = local.env_poc
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.secret_env_poc
        content {
          name        = env.key
          secret_name = env.value
        }
      }
    }

    # Wake on work in the Celery "poc" list; idle costs nothing.
    custom_scale_rule {
      name             = "poc-queue"
      custom_rule_type = "redis"
      metadata = {
        address    = "${local.redis_name}:6379"
        listName   = "poc"
        listLength = "1"
      }

      authentication {
        secret_name       = "redis-auth"
        trigger_parameter = "password"
      }
    }
  }
}

###############################################################################
# Jobs
###############################################################################

resource "azurerm_container_app_job" "sast" {
  count = local.workloads

  name                         = "${var.prefix}-sast"
  location                     = var.location
  resource_group_name          = var.resource_group_name
  container_app_environment_id = var.environment_id
  workload_profile_name        = var.scan_profile_name
  tags                         = var.tags

  # Retries happen above this layer: the orphan sweep re-dispatches and the
  # replacement resumes from the AI SAST checkpoints, where a platform retry
  # would restart from nothing.
  replica_retry_limit        = 0
  replica_timeout_in_seconds = var.scan_timeout_seconds

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identities.app.id]
  }

  registry {
    server   = var.registry_server
    identity = var.identities.app.id
  }

  dynamic "secret" {
    for_each = toset(values(local.secret_env_full))
    content {
      name                = secret.value
      key_vault_secret_id = var.secret_ids[secret.value]
      identity            = var.identities.app.id
    }
  }

  template {
    container {
      name    = "sast"
      image   = local.images.worker
      cpu     = var.scan_cpu
      memory  = var.scan_memory
      command = concat(local.sh_prefix, ["python", "/app/work_job.py"])

      # SCAN_ID is absent on purpose: aca.py adds it per execution.
      dynamic "env" {
        for_each = local.env_app
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.secret_env_full
        content {
          name        = env.key
          secret_name = env.value
        }
      }

      # The clone (/var/tmp/scansuite/sast/<scan_id>) stays on the replica's
      # own disk: on the NFS share a Django clone took 321 s instead of 3 s,
      # and reading its sources 600 times longer (dev test report, T10). It
      # dies with the replica, so a killed scan leaves nothing behind.
    }
  }
}

resource "azurerm_container_app_job" "migrate" {
  count = local.workloads

  name                         = "${var.prefix}-migrate"
  location                     = var.location
  resource_group_name          = var.resource_group_name
  container_app_environment_id = var.environment_id
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  # One attempt: the migration is idempotent, but a failure means someone
  # should look rather than let it retry into the same wall.
  replica_retry_limit        = 0
  replica_timeout_in_seconds = 1800

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identities.migrate.id]
  }

  registry {
    server   = var.registry_server
    identity = var.identities.migrate.id
  }

  dynamic "secret" {
    for_each = toset(values(local.secret_env_full))
    content {
      name                = secret.value
      key_vault_secret_id = var.secret_ids[secret.value]
      identity            = var.identities.migrate.id
    }
  }

  template {
    container {
      name    = "migrate"
      image   = local.images.worker
      cpu     = 1
      memory  = "2Gi"
      command = concat(local.sh_prefix, ["python", "/app/migrate.py"])

      dynamic "env" {
        for_each = local.env_migrate
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.secret_env_full
        content {
          name        = env.key
          secret_name = env.value
        }
      }
    }
  }
}

# The app identity starts, reads and stops scan executions - and nothing else
# can. Scoped to this one job.
resource "azurerm_role_assignment" "dispatcher" {
  count = local.workloads

  scope              = azurerm_container_app_job.sast[0].id
  role_definition_id = var.dispatcher_role_definition_id
  principal_id       = var.identities.app.principal_id
  principal_type     = "ServicePrincipal"
}
