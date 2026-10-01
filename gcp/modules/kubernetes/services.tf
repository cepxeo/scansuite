###############################################################################
# Services.
#
# The cloud.google.com/neg annotation makes GKE create a standalone zonal
# network endpoint group per zone. The load balancer in modules/lb attaches to
# those NEGs directly, so traffic goes GFE -> pod, skipping kube-proxy and the
# node port hop. It also means no Ingress, no BackendConfig and no Gateway
# object - the whole front end is native google_compute_* resources, which is
# what lets a single terraform apply build it. See README, "No CRDs".
#
# web is the only service that serves HTTP. The workers are Celery consumers;
# nothing connects to them.
###############################################################################

resource "kubernetes_service_v1" "web" {
  metadata {
    name      = "web"
    namespace = local.ns
    annotations = {
      "cloud.google.com/neg" = jsonencode({
        exposed_ports = { "5000" = { name = local.web_neg } }
      })
    }
  }

  spec {
    type     = "ClusterIP"
    selector = { app = "web" }

    port {
      name        = "http"
      port        = 5000
      target_port = 5000
      protocol    = "TCP"
    }
  }

  depends_on = [kubernetes_namespace_v1.this]
}

# Governing service for the worker StatefulSet. Nothing connects to it - the
# StatefulSet API requires a headless service to own its pod DNS names.
resource "kubernetes_service_v1" "scan_engine_headless" {
  metadata {
    name      = "scan-engine"
    namespace = local.ns
  }

  spec {
    cluster_ip = "None"
    selector   = { app = "scan-engine" }

    port {
      name = "placeholder"
      port = 9999
    }
  }

  depends_on = [kubernetes_namespace_v1.this]
}
