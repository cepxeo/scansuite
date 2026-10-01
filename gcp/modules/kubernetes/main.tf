locals {
  ns = var.namespace

  web_neg = "${var.prefix}-web-neg"

  common_labels = {
    "app.kubernetes.io/part-of"    = "scansuite"
    "app.kubernetes.io/managed-by" = "terraform"
  }

  # Non-secret configuration. Three entries carry real weight:
  #   LOG_FILE=/dev/stdout  - logging.basicConfig writes to a file. Point that
  #                           file at stdout and the GKE agent ships everything
  #                           to Cloud Logging, with no code change.
  #   STORAGE_URL           - deliberately absent. Setting GCP_STORAGE_BUCKET
  #                           makes object_store.py write "gcs:" refs; the
  #                           SeaweedFS path is not used.
  #   ENABLE_DYNAMIC_SCANS  - forced off. Dynamic and infrastructure scanning
  #                           launch scanner containers through a Docker daemon,
  #                           and this deployment has none. See README,
  #                           "Static analysis only".
  config = merge(var.redis_config, {
    PS_DATABASE_HOST              = var.db_host
    PS_DATABASE_PORT              = "5432"
    PS_DATABASE_NAME              = var.db_name
    PS_DATABASE_USER              = var.db_user
    SCANSUITE_ACTIVE_WRAPPING_KEY = "k1"

    CELERY_HOST = var.redis_host

    GCP_STORAGE_BUCKET           = var.artifact_bucket
    GCP_STORAGE_PROJECT          = var.project_id
    GCP_STORAGE_PREFIX           = "scansuite"
    GCP_STORAGE_CREDENTIALS_PATH = "/key/key.json"

    # The licence and key are decoded into /key at container start from the
    # base64 secrets below; the image looks for the licence in PYARMOR_RKEY.
    PYARMOR_RKEY             = "/key"
    PYARMOR_LICENSE_FILENAME = var.pyarmor_licence_filename

    LOG_FILE = "/dev/stdout"

    # Both stated explicitly rather than left to the defaults, because the two
    # platforms differ here and a silent default is the wrong thing to rely on.
    #
    # Scans run as Celery tasks in the scan-engine StatefulSet, not as Cloud
    # Run job executions.
    EXECUTION_BACKEND = "celery"

    ENABLE_STATIC_SCANS  = var.enable_static_scans
    ENABLE_DYNAMIC_SCANS = var.enable_dynamic_scans

    TZ = var.timezone
  })

  # Operational secrets for the full-trust workloads.
  secrets = {
    PS_DATABASE_PASSWORD = var.db_password
    REDIS_PASSWORD       = var.redis_password
    SECRET_KEY           = var.flask_secret_key
  }

  # worker-poc runs model-written code: database, broker and the licence its
  # protected image needs - never SECRET_KEY, the wrapping keys or the LLM key.
  poc_secrets = {
    PS_DATABASE_PASSWORD = var.db_password
    REDIS_PASSWORD       = var.redis_password
    PYARMOR_LICENSE_B64  = var.pyarmor_license_b64
  }

  # The /key material, in its own Secret so that worker-poc - which runs
  # model-written code - can be given the operational secrets without ever
  # receiving the licence, the LLM key or the secret wrapping keys.
  key_secrets = merge(
    {
      PYARMOR_LICENSE_B64     = var.pyarmor_license_b64
      SCANSUITE_WRAPPING_KEYS = var.team_wrapping_keys
    },
    var.llm_sa_key_b64 != "" ? { GCP_KEY_JSON_B64 = var.llm_sa_key_b64 } : {}
  )

  # Decode the base64 licence into $PYARMOR_RKEY (/key by default; worker-poc
  # runs as uid 10001 on a read-only filesystem and points it under /tmp), the
  # GCP key into /key, and write Memorystore's CA where REDIS_CA_CERTS says.
  # Each is skipped when absent or already present. $VAR without braces is a
  # shell reference; $${...} escapes HCL interpolation.
  key_bootstrap = <<-EOT
    set -e
    key_dir="$${PYARMOR_RKEY:-/key}"
    mkdir -p "$key_dir"
    if [ -n "$PYARMOR_LICENSE_B64" ] && [ -n "$PYARMOR_LICENSE_FILENAME" ] && [ ! -f "$key_dir/$PYARMOR_LICENSE_FILENAME" ]; then
      printf %s "$PYARMOR_LICENSE_B64" | base64 -d > "$key_dir/$PYARMOR_LICENSE_FILENAME"
      chmod 0400 "$key_dir/$PYARMOR_LICENSE_FILENAME"
    fi
    if [ -n "$GCP_KEY_JSON_B64" ] && [ ! -f /key/key.json ]; then
      mkdir -p /key
      printf %s "$GCP_KEY_JSON_B64" | base64 -d > /key/key.json
      chmod 0400 /key/key.json
    fi
    if [ -n "$REDIS_CA_PEM" ] && [ -n "$REDIS_CA_CERTS" ]; then
      printf '%s\n' "$REDIS_CA_PEM" > "$REDIS_CA_CERTS"
    fi
  EOT

  sh_prefix = ["/bin/sh", "-lc", "${local.key_bootstrap}\nexec \"$0\" \"$@\""]

  use_pull_secret = var.dockerhub_username != "" && var.dockerhub_token != ""
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name   = local.ns
    labels = local.common_labels
  }
}

###############################################################################
# Service accounts - each bound to a Google service account by Workload Identity
###############################################################################

resource "kubernetes_service_account_v1" "app" {
  for_each = toset(["web", "scan-engine", "worker-admin", "celery-beat"])

  metadata {
    name      = each.value
    namespace = local.ns
    annotations = {
      "iam.gke.io/gcp-service-account" = var.app_service_account_email
    }
  }

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_service_account_v1" "poc" {
  metadata {
    name      = "worker-poc"
    namespace = local.ns
    annotations = {
      "iam.gke.io/gcp-service-account" = var.poc_service_account_email
    }
  }

  depends_on = [kubernetes_namespace_v1.this]
}

###############################################################################
# Configuration and secrets
###############################################################################

resource "kubernetes_config_map_v1" "app" {
  metadata {
    name      = "scansuite-config"
    namespace = local.ns
  }

  data = local.config

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_secret_v1" "app" {
  metadata {
    name      = "scansuite-secrets"
    namespace = local.ns
  }

  data = local.secrets
  type = "Opaque"

  depends_on = [kubernetes_namespace_v1.this]
}

# worker-poc's reduced set: database, broker and licence.
resource "kubernetes_secret_v1" "poc" {
  metadata {
    name      = "scansuite-poc-secrets"
    namespace = local.ns
  }

  data = local.poc_secrets
  type = "Opaque"

  depends_on = [kubernetes_namespace_v1.this]
}

# The base64 licence and LLM key, decoded into /key at container start. In its
# own Secret, referenced by every workload except worker-poc.
resource "kubernetes_secret_v1" "key_env" {
  metadata {
    name      = "scansuite-key-secrets"
    namespace = local.ns
  }

  data = local.key_secrets
  type = "Opaque"

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_secret_v1" "dockerhub" {
  count = local.use_pull_secret ? 1 : 0

  metadata {
    name      = "dockerhub"
    namespace = local.ns
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (var.image_pull_registry) = {
          username = var.dockerhub_username
          password = var.dockerhub_token
          auth     = base64encode("${var.dockerhub_username}:${var.dockerhub_token}")
        }
      }
    })
  }

  depends_on = [kubernetes_namespace_v1.this]
}

###############################################################################
# Network policy
#
# Ingress is denied by default and opened only for web, from the Google Front
# End ranges (which carry both health checks and real client traffic) and from
# the node and pod ranges (kubelet probes). Nothing connects to the workers.
#
# Egress is left open: the workers clone repositories from arbitrary git hosts
# and call the Vertex AI endpoint.
###############################################################################

resource "kubernetes_network_policy_v1" "default_deny_ingress" {
  metadata {
    name      = "default-deny-ingress"
    namespace = local.ns
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_network_policy_v1" "allow_frontends" {
  metadata {
    name      = "allow-load-balancer-and-probes"
    namespace = local.ns
  }

  spec {
    pod_selector {
      match_labels = { app = "web" }
    }

    policy_types = ["Ingress"]

    ingress {
      dynamic "from" {
        for_each = concat(var.lb_source_cidrs, var.probe_source_cidrs)
        content {
          ip_block {
            cidr = from.value
          }
        }
      }

      ports {
        port     = "5000"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.this]
}
