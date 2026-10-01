###############################################################################
# Cloud Run deployment.
#
#   migrate      Job, run once per release.  Owns every schema change and the
#                deploy-time sweep of unfinished scans. No application
#                process does DDL; each refuses to start until the schema is
#                current.
#   sast         Job, one execution per scan.  Started by the admin worker
#                through worker/execution/cloudrun.py, which passes SCAN_ID as
#                the only override; every other argument comes from the
#                scan_jobs row.
#   web          Service.
#   worker-admin Worker pool, queue "admin".
#   celery-beat  Worker pool, manual scaling pinned to one instance.
#   worker-poc   Worker pool, queue "poc".  Cloud Run already runs workloads
#                under gVisor, so this gets the isolation the GKE deployment
#                needs a dedicated sandbox node pool for.
#
# The /key files (PyArmor licence, service-account JSON) are not mounted.  They
# arrive as base64 secret env vars and a tiny shell prelude decodes them into
# /key before the real command runs.  worker-poc
# is the exception: it runs model-written code, so it gets neither the prelude
# nor the licence/key secrets in its environment.
###############################################################################

locals {
  # Direct VPC egress: Cloud SQL and Memorystore are on private IPs, and the
  # workers need outbound internet for git clones and Vertex AI.
  vpc_egress = "ALL_TRAFFIC"

  # The migrate job owns the schema on every platform; services and job
  # executions only check that it is current.
  env = merge(var.config, {
    EXECUTION_BACKEND = "cloudrun"
    CLOUDRUN_PROJECT  = var.project_id
    CLOUDRUN_REGION   = var.region
    CLOUDRUN_JOB_NAME = "${var.prefix}-sast"
  })

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

  # sh -lc 'prelude; exec "$0" "$@"' python app.py  ->  $0=python, $@=app.py.
  sh_prefix = ["/bin/sh", "-lc", "${local.key_bootstrap}\nexec \"$0\" \"$@\""]

  cmd_web     = concat(local.sh_prefix, ["python", "app.py"])
  cmd_admin   = concat(local.sh_prefix, ["python", "work_admin.py"])
  cmd_beat    = concat(local.sh_prefix, ["/app/run_beat"])
  cmd_migrate = concat(local.sh_prefix, ["python", "/app/migrate.py"])
  cmd_sast    = concat(local.sh_prefix, ["python", "/app/work_job.py"])
}

###############################################################################
# Jobs
###############################################################################

resource "google_cloud_run_v2_job" "migrate" {
  project             = var.project_id
  name                = "${var.prefix}-migrate"
  location            = var.region
  labels              = var.labels
  deletion_protection = false

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account = var.migrate_service_account_email
      # One attempt: these helpers are idempotent, but a failure means someone
      # should look rather than let it retry into the same wall.
      max_retries = 0
      timeout     = "1800s"

      vpc_access {
        egress = local.vpc_egress
        network_interfaces {
          network    = var.network_name
          subnetwork = var.subnet_name
        }
      }

      containers {
        image   = var.image_worker
        command = local.cmd_migrate

        dynamic "env" {
          for_each = local.env
          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = var.secret_env
          content {
            name = env.key
            value_source {
              secret_key_ref {
                secret  = env.value
                version = "latest"
              }
            }
          }
        }

        resources {
          limits = {
            cpu    = "2"
            memory = "4Gi"
          }
        }
      }
    }
  }
}

resource "google_cloud_run_v2_job" "sast" {
  project             = var.project_id
  name                = "${var.prefix}-sast"
  location            = var.region
  labels              = var.labels
  deletion_protection = var.deletion_protection

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account = var.app_service_account_email

      # Retries are handled above this layer.  Cloud Run would restart the task
      # from the beginning, whereas re-dispatching through the orphan sweep
      # resumes from the AI SAST checkpoints already in the database.
      max_retries = 0
      timeout     = "${var.scan_task_timeout_seconds}s"

      vpc_access {
        egress = local.vpc_egress
        network_interfaces {
          network    = var.network_name
          subnetwork = var.subnet_name
        }
      }

      containers {
        image   = var.image_worker
        command = local.cmd_sast

        # SCAN_ID is deliberately absent: it is supplied per execution as an
        # override by worker/execution/cloudrun.py.  Everything else the scan
        # needs is read from its scan_jobs row.
        dynamic "env" {
          for_each = local.env
          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = var.secret_env
          content {
            name = env.key
            value_source {
              secret_key_ref {
                secret  = env.value
                version = "latest"
              }
            }
          }
        }

        resources {
          limits = {
            cpu    = var.scan_cpu
            memory = var.scan_memory
          }
        }
      }
    }
  }
}

###############################################################################
# Web service
###############################################################################

resource "google_cloud_run_v2_service" "web" {
  project             = var.project_id
  name                = "${var.prefix}-web"
  location            = var.region
  labels              = var.labels
  deletion_protection = var.deletion_protection

  # internal_only: reachable only from inside the VPC / perimeter, no LB.
  # Otherwise: only the external load balancer (Cloud Armor + X-Real-IP) reaches it.
  ingress = var.internal_only ? "INGRESS_TRAFFIC_INTERNAL_ONLY" : "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  # Browsers carry no Google identity token, so Cloud Run's invoker check would
  # refuse every request ("The request was not authenticated"). The ingress
  # above is the network gate, and the application authenticates its users.
  # Disabling the check, rather than granting allUsers the invoker role, also
  # works where an organisation policy forbids allUsers bindings.
  invoker_iam_disabled = true

  template {
    service_account = var.app_service_account_email
    timeout         = "3600s"

    scaling {
      min_instance_count = var.web_min_instances
      max_instance_count = var.web_max_instances
    }

    vpc_access {
      egress = local.vpc_egress
      network_interfaces {
        network    = var.network_name
        subnetwork = var.subnet_name
      }
    }

    containers {
      image   = var.image_web
      command = local.cmd_web

      ports {
        name           = "http1"
        container_port = 5000
      }

      dynamic "env" {
        for_each = local.env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }

      startup_probe {
        # Cloud Run allows four minutes total.  With migrations moved to the
        # job this is Flask start plus a database connection, but leave room
        # for a cold Cloud SQL connection.
        initial_delay_seconds = 10
        period_seconds        = 10
        failure_threshold     = 20
        timeout_seconds       = 5
        tcp_socket {
          port = 5000
        }
      }

      resources {
        limits = {
          cpu    = "2"
          memory = "4Gi"
        }
        cpu_idle          = false
        startup_cpu_boost = true
      }
    }
  }

  lifecycle {
    # client/client_version change with whoever last touched the service. The
    # service-level scaling block is filled in by the API (zeros) although the
    # revision template carries the real scaling; without ignoring it every
    # apply "updates" the service.
    ignore_changes = [client, client_version, scaling]
  }
}

###############################################################################
# Worker pools
###############################################################################

resource "google_cloud_run_v2_worker_pool" "admin" {
  project             = var.project_id
  name                = "${var.prefix}-worker-admin"
  location            = var.region
  labels              = var.labels
  deletion_protection = var.deletion_protection
  launch_stage        = "GA"

  scaling {
    scaling_mode          = "MANUAL"
    manual_instance_count = var.admin_instances
  }

  lifecycle {
    # MANUAL is the only mode set here, and the API does not report it back,
    # so without this every apply would "add" it again.
    ignore_changes = [scaling[0].scaling_mode]
  }

  template {
    service_account = var.app_service_account_email

    vpc_access {
      egress = local.vpc_egress
      network_interfaces {
        network    = var.network_name
        subnetwork = var.subnet_name
      }
    }

    containers {
      image   = var.image_worker
      command = local.cmd_admin

      dynamic "env" {
        for_each = local.env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "2Gi"
        }
      }
    }
  }
}

resource "google_cloud_run_v2_worker_pool" "beat" {
  project             = var.project_id
  name                = "${var.prefix}-celery-beat"
  location            = var.region
  labels              = var.labels
  deletion_protection = var.deletion_protection
  launch_stage        = "GA"

  # Exactly one, always.  Two beat instances double every scheduled scan.
  scaling {
    scaling_mode          = "MANUAL"
    manual_instance_count = 1
  }

  lifecycle {
    # MANUAL is the only mode set here, and the API does not report it back,
    # so without this every apply would "add" it again.
    ignore_changes = [scaling[0].scaling_mode]
  }

  template {
    service_account = var.app_service_account_email

    vpc_access {
      egress = local.vpc_egress
      network_interfaces {
        network    = var.network_name
        subnetwork = var.subnet_name
      }
    }

    containers {
      image   = var.image_worker
      command = local.cmd_beat

      dynamic "env" {
        for_each = local.env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
      }
    }
  }
}

resource "google_cloud_run_v2_worker_pool" "poc" {
  project             = var.project_id
  name                = "${var.prefix}-worker-poc"
  location            = var.region
  labels              = var.labels
  deletion_protection = var.deletion_protection
  launch_stage        = "GA"

  scaling {
    scaling_mode          = "MANUAL"
    manual_instance_count = var.poc_instances
  }

  lifecycle {
    # MANUAL is the only mode set here, and the API does not report it back,
    # so without this every apply would "add" it again.
    ignore_changes = [scaling[0].scaling_mode]
  }

  template {
    # Its own identity: this container executes model-generated exploit code.
    # var.secret_env_poc is the reduced set - database, broker and the licence
    # its protected image cannot start without - so SECRET_KEY, the wrapping
    # keys and the LLM key never enter this environment.
    service_account = var.poc_service_account_email

    vpc_access {
      egress = local.vpc_egress
      network_interfaces {
        network    = var.network_name
        subnetwork = var.subnet_name
      }
    }

    containers {
      image   = var.image_worker_poc
      command = concat(local.sh_prefix, ["python", "/app/work_poc.py"])

      dynamic "env" {
        # The image runs as uid 10001, which cannot create /key: the licence is
        # decoded under /tmp instead.
        for_each = merge(local.env, { PYARMOR_RKEY = "/tmp/key" })
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.secret_env_poc
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "2Gi"
        }
      }
    }
  }
}

###############################################################################
# Permissions
#
# The admin worker starts scan jobs, so it needs to run them.  Nothing else
# does.
###############################################################################

# Each scan starts an execution with overrides (its SCAN_ID), which needs
# run.jobs.runWithOverrides: roles/run.invoker lacks it, and every scan was
# refused with 403. This role also reads and cancels the executions. Granted on
# the scan job alone - starting a job with overrides runs code as its identity.
resource "google_cloud_run_v2_job_iam_member" "sast_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_job.sast.name
  role     = "roles/run.jobsExecutorWithOverrides"
  member   = "serviceAccount:${var.app_service_account_email}"
}

# Reading execution state is what lets the orphan sweep tell "still running"
# from "gone", and cancelling needs the same surface.
resource "google_project_iam_member" "executions_viewer" {
  project = var.project_id
  role    = "roles/run.viewer"
  member  = "serviceAccount:${var.app_service_account_email}"
}
