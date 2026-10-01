###############################################################################
# web
#
# replicas = 1 and strategy = Recreate are load-bearing, not conservatism.
# The migrate init container (migrate.py) cancels scans left unfinished by the
# previous release each time a web pod is created, so a second pod - or the
# extra pod a RollingUpdate briefly creates - would cancel running scans.
# Moving migrate.py to a Kubernetes Job run once per release lifts this.
###############################################################################

resource "kubernetes_deployment_v1" "web" {
  metadata {
    name      = "web"
    namespace = local.ns
    labels    = merge(local.common_labels, { app = "web" })
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { app = "web" }
    }

    template {
      metadata {
        labels = merge(local.common_labels, { app = "web" })
      }

      spec {
        service_account_name = kubernetes_service_account_v1.app["web"].metadata[0].name

        dynamic "image_pull_secrets" {
          for_each = local.use_pull_secret ? [1] : []
          content {
            name = kubernetes_secret_v1.dockerhub[0].metadata[0].name
          }
        }

        # The migration job: brings the database to the head revision before
        # web starts (web and workers refuse to run against an older schema;
        # workers that start first exit and are restarted until it is current).
        init_container {
          name    = "migrate"
          image   = var.image_web
          command = concat(local.sh_prefix, ["python", "migrate.py"])

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.app.metadata[0].name
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.app.metadata[0].name
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.key_env.metadata[0].name
            }
          }
        }

        container {
          name    = "web"
          image   = var.image_web
          command = concat(local.sh_prefix, ["python", "app.py"])

          port {
            name           = "http"
            container_port = 5000
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.app.metadata[0].name
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.app.metadata[0].name
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.key_env.metadata[0].name
            }
          }


          # Startup waits for Cloud SQL and checks the schema revision. Ten
          # minutes of grace, then declare it broken.
          startup_probe {
            http_get {
              path = "/log_in"
              port = 5000
            }
            period_seconds    = 10
            failure_threshold = 60
          }

          readiness_probe {
            http_get {
              path = "/log_in"
              port = 5000
            }
            period_seconds    = 15
            timeout_seconds   = 5
            failure_threshold = 3
          }

          liveness_probe {
            tcp_socket {
              port = 5000
            }
            period_seconds    = 30
            failure_threshold = 5
          }

          resources {
            requests = { cpu = "500m", memory = "1Gi" }
            limits   = { cpu = "2", memory = "4Gi" }
          }
        }

      }
    }
  }

  timeouts {
    create = "20m"
    update = "20m"
  }

  depends_on = [kubernetes_config_map_v1.app, kubernetes_secret_v1.app, kubernetes_secret_v1.key_env]
}

###############################################################################
# scan-engine - the static analysis worker (Celery queue "celery")
#
# A StatefulSet rather than a Deployment because each replica needs its own
# scratch volume: worker/tasks.py clones the repository under test into
# /var/tmp/scansuite/sast/<scan_id>, and worker/helper/git_helper.py writes
# credential helpers under /var/tmp/scansuite/git-auth.
#
# No Docker daemon. This deployment runs AI-native static analysis, and the
# analysis tools that are not the model - Trivy, Nosey Parker, gitleaks,
# TruffleHog - are installed as native binaries in the worker image
# (worker/Dockerfile) and execute in this container. Scanner images are never
# launched. See README, "Static analysis only", for what that rules out.
###############################################################################

resource "kubernetes_stateful_set_v1" "scan_engine" {
  metadata {
    name      = "scan-engine"
    namespace = local.ns
    labels    = merge(local.common_labels, { app = "scan-engine" })
  }

  spec {
    service_name          = kubernetes_service_v1.scan_engine_headless.metadata[0].name
    replicas              = var.worker_replicas
    pod_management_policy = "OrderedReady"

    selector {
      match_labels = { app = "scan-engine" }
    }

    update_strategy {
      type = "RollingUpdate"
    }

    template {
      metadata {
        labels = merge(local.common_labels, { app = "scan-engine" })
      }

      spec {
        service_account_name = kubernetes_service_account_v1.app["scan-engine"].metadata[0].name
        node_selector        = { "cloud.google.com/gke-nodepool" = "scan-engine" }

        # Celery's task_time_limit is 48h and an AI SAST run over a large
        # repository is measured in hours. Give it time to finish rather than
        # killing it during a drain.
        termination_grace_period_seconds = 3600

        toleration {
          key      = "workload"
          operator = "Equal"
          value    = "scan-engine"
          effect   = "NoSchedule"
        }

        dynamic "image_pull_secrets" {
          for_each = local.use_pull_secret ? [1] : []
          content {
            name = kubernetes_secret_v1.dockerhub[0].metadata[0].name
          }
        }

        container {
          name    = "worker"
          image   = var.image_worker
          command = concat(local.sh_prefix, ["python", "work.py"])

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.app.metadata[0].name
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.app.metadata[0].name
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.key_env.metadata[0].name
            }
          }

          volume_mount {
            name       = "scratch"
            mount_path = "/var/tmp"
          }


          # Trivy keeps its vulnerability database under /root/.cache, so the
          # root filesystem stays writable and the container stays root.
          resources {
            requests = { cpu = "500m", memory = "2Gi" }
            limits   = { cpu = "3", memory = "8Gi" }
          }
        }

      }
    }

    volume_claim_template {
      metadata {
        name = "scratch"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = "premium-rwo"
        resources {
          requests = {
            storage = "${var.scratch_disk_gb}Gi"
          }
        }
      }
    }
  }

  timeouts {
    create = "25m"
    update = "25m"
  }

  depends_on = [kubernetes_config_map_v1.app, kubernetes_secret_v1.app, kubernetes_secret_v1.key_env]
}

resource "kubernetes_pod_disruption_budget_v1" "scan_engine" {
  metadata {
    name      = "scan-engine"
    namespace = local.ns
  }

  spec {
    # With one replica this refuses voluntary eviction outright, which is the
    # intent: a node drain should not silently kill a running analysis. GKE
    # force-drains after its own timeout, so upgrades still complete.
    min_available = 1
    selector {
      match_labels = { app = "scan-engine" }
    }
  }

  depends_on = [kubernetes_namespace_v1.this]
}

###############################################################################
# worker-admin - orchestration (Celery queue "admin")
#
# Creates scan tasks, cancels them, and pushes findings to DefectDojo and
# Nessus. It touches no files, so it needs no scratch volume, and with no
# Docker daemon in the deployment it no longer has to sit beside the scan
# worker - under docker-compose the two shared a socket so that
# stop_containers could reach the daemon that started the scanners.
#
# stop_containers still runs `docker ps` when a scan is cancelled and will fail
# to find the binary. That is harmless here: with no scanner containers there is
# nothing for it to kill, and the scan row is marked Cancelled either way.
###############################################################################

resource "kubernetes_deployment_v1" "worker_admin" {
  metadata {
    name      = "worker-admin"
    namespace = local.ns
    labels    = merge(local.common_labels, { app = "worker-admin" })
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { app = "worker-admin" }
    }

    template {
      metadata {
        labels = merge(local.common_labels, { app = "worker-admin" })
      }

      spec {
        service_account_name = kubernetes_service_account_v1.app["worker-admin"].metadata[0].name

        termination_grace_period_seconds = 300

        dynamic "image_pull_secrets" {
          for_each = local.use_pull_secret ? [1] : []
          content {
            name = kubernetes_secret_v1.dockerhub[0].metadata[0].name
          }
        }

        container {
          name    = "worker-admin"
          image   = var.image_worker
          command = concat(local.sh_prefix, ["python", "work_admin.py"])

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.app.metadata[0].name
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.app.metadata[0].name
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.key_env.metadata[0].name
            }
          }


          resources {
            requests = { cpu = "200m", memory = "512Mi" }
            limits   = { cpu = "1", memory = "2Gi" }
          }
        }

      }
    }
  }

  timeouts {
    create = "15m"
    update = "15m"
  }

  depends_on = [kubernetes_config_map_v1.app, kubernetes_secret_v1.app, kubernetes_secret_v1.key_env]
}

###############################################################################
# celery-beat
#
# Exactly one instance, always. start_beat.py builds the whole beat_schedule
# once at import time from the SavedScan table, so a schedule edited in the UI
# is invisible until this process restarts - hence the CronJob below.
###############################################################################

resource "kubernetes_deployment_v1" "celery_beat" {
  metadata {
    name      = "celery-beat"
    namespace = local.ns
    labels    = merge(local.common_labels, { app = "celery-beat" })
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { app = "celery-beat" }
    }

    template {
      metadata {
        labels = merge(local.common_labels, { app = "celery-beat" })
      }

      spec {
        service_account_name = kubernetes_service_account_v1.app["celery-beat"].metadata[0].name

        dynamic "image_pull_secrets" {
          for_each = local.use_pull_secret ? [1] : []
          content {
            name = kubernetes_secret_v1.dockerhub[0].metadata[0].name
          }
        }

        container {
          name    = "celery-beat"
          image   = var.image_worker
          command = concat(local.sh_prefix, ["/app/run_beat"])

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.app.metadata[0].name
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.app.metadata[0].name
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.key_env.metadata[0].name
            }
          }


          # celery.conf.beat_schedule_filename points here.
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "500m", memory = "1Gi" }
          }
        }


        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }

  timeouts {
    create = "15m"
    update = "15m"
  }

  depends_on = [kubernetes_config_map_v1.app, kubernetes_secret_v1.app, kubernetes_secret_v1.key_env]
}

###############################################################################
# worker-poc
#
# The only workload here that is genuinely stateless and safe to scale. It runs
# model-generated exploit code in-process (run_poc_locally, sandboxed with
# setrlimit), so it gets gVisor underneath, a read-only root filesystem, no
# capabilities - and no /key mount, because it needs neither Cloud Storage nor
# Vertex AI.
###############################################################################

resource "kubernetes_deployment_v1" "worker_poc" {
  metadata {
    name      = "worker-poc"
    namespace = local.ns
    labels    = merge(local.common_labels, { app = "worker-poc" })
  }

  spec {
    replicas = var.poc_replicas

    selector {
      match_labels = { app = "worker-poc" }
    }

    template {
      metadata {
        labels = merge(local.common_labels, { app = "worker-poc" })
      }

      spec {
        service_account_name = kubernetes_service_account_v1.poc.metadata[0].name
        runtime_class_name   = "gvisor"
        node_selector        = { "cloud.google.com/gke-nodepool" = "poc-sandbox" }

        toleration {
          key      = "sandbox.gke.io/runtime"
          operator = "Equal"
          value    = "gvisor"
          effect   = "NoSchedule"
        }

        security_context {
          run_as_user     = 10001
          run_as_group    = 10001
          run_as_non_root = true
        }

        dynamic "image_pull_secrets" {
          for_each = local.use_pull_secret ? [1] : []
          content {
            name = kubernetes_secret_v1.dockerhub[0].metadata[0].name
          }
        }

        container {
          name    = "worker-poc"
          image   = var.image_worker_poc
          command = concat(local.sh_prefix, ["python", "/app/work_poc.py"])

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.app.metadata[0].name
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.poc.metadata[0].name
            }
          }

          # The root filesystem is read-only and /tmp the only writable path:
          # the licence is decoded there.
          env {
            name  = "PYARMOR_RKEY"
            value = "/tmp/key"
          }

          security_context {
            read_only_root_filesystem  = true
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          resources {
            requests = { cpu = "250m", memory = "512Mi" }
            limits   = { cpu = "1", memory = "2Gi" }
          }
        }

        volume {
          name = "tmp"
          empty_dir {
            medium     = "Memory"
            size_limit = "64Mi"
          }
        }
      }
    }
  }

  timeouts {
    create = "20m"
    update = "20m"
  }

  depends_on = [kubernetes_config_map_v1.app, kubernetes_secret_v1.app]
}

###############################################################################
# beat-restarter
#
# Workaround, not architecture. start_beat.py reads the schedule once, so a scan
# scheduled through the UI would otherwise never fire. Rolling the deployment
# hourly bounds the delay at an hour. Delete this the day start_beat.py grows a
# scheduler that re-reads SavedScan.
###############################################################################

resource "kubernetes_service_account_v1" "beat_restarter" {
  metadata {
    name      = "beat-restarter"
    namespace = local.ns
  }

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_role_v1" "beat_restarter" {
  metadata {
    name      = "beat-restarter"
    namespace = local.ns
  }

  rule {
    api_groups     = ["apps"]
    resources      = ["deployments"]
    resource_names = ["celery-beat"]
    verbs          = ["get", "patch"]
  }

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_role_binding_v1" "beat_restarter" {
  metadata {
    name      = "beat-restarter"
    namespace = local.ns
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.beat_restarter.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.beat_restarter.metadata[0].name
    namespace = local.ns
  }
}

resource "kubernetes_cron_job_v1" "beat_restarter" {
  metadata {
    name      = "beat-restarter"
    namespace = local.ns
  }

  spec {
    schedule                      = "7 * * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3

    job_template {
      metadata {}
      spec {
        backoff_limit = 2
        template {
          metadata {}
          spec {
            service_account_name = kubernetes_service_account_v1.beat_restarter.metadata[0].name
            restart_policy       = "OnFailure"

            container {
              name    = "kubectl"
              image   = "bitnami/kubectl:1.31"
              command = ["kubectl", "rollout", "restart", "deployment/celery-beat", "-n", local.ns]

              resources {
                requests = { cpu = "10m", memory = "64Mi" }
                limits   = { cpu = "200m", memory = "256Mi" }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_role_binding_v1.beat_restarter, kubernetes_deployment_v1.celery_beat]
}
