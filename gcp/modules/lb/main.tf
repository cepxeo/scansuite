###############################################################################
# Global external Application Load Balancer - the replacement for nginx.
#
# Built from native google_compute_* resources against standalone zonal NEGs,
# rather than a GKE Ingress or a Gateway. Ingress and Gateway both need their
# settings expressed as CRDs (BackendConfig, FrontendConfig, Gateway,
# HTTPRoute), and Terraform cannot plan a CRD against a cluster that does not
# exist yet. Everything here is planable from the first apply.
#
# Two settings carry the behaviour nginx used to provide:
#
#   timeout_sec 3600        replaces proxy_read_timeout 600. There is no
#                           request body limit on this load balancer, so
#                           client_max_body_size 2000M needs no equivalent.
#   X-Real-IP header        nginx set `proxy_set_header X-Real-IP $remote_addr`,
#                           and authentication/auth.py keys its rate limiter off
#                           exactly that header, falling back to remote_addr.
#                           Behind a load balancer remote_addr is a Google front
#                           end shared by every client, so without this header
#                           all users would share one 40-requests-per-minute
#                           bucket and lock each other out.
#   single default backend  the nginx /aidocs location block is gone with the
#                           AI documentation site; every path goes to web.
###############################################################################

resource "google_compute_global_address" "lb" {
  project = var.project_id
  name    = "${var.prefix}-lb-ip"
}

###############################################################################
# Backends
###############################################################################

# Two shapes of backend, one load balancer in front of either.
#
# cloudrun  a serverless NEG pointing at the Cloud Run service.  Health checks
#           are not applicable and must be omitted; Cloud Run manages instance
#           health itself.
# gke       standalone zonal NEGs created by the NEG controller from the
#           Service annotation, one per zone.
data "google_compute_network_endpoint_group" "web" {
  for_each = var.backend_mode == "gke" ? toset(var.zones) : toset([])

  project = var.project_id
  name    = var.web_neg_name
  zone    = each.value
}

resource "google_compute_region_network_endpoint_group" "cloudrun" {
  count = var.backend_mode == "cloudrun" ? 1 : 0

  project               = var.project_id
  name                  = "${var.prefix}-web-serverless-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = var.cloud_run_service
  }
}

# GKE only. A serverless NEG has no health check: Cloud Run decides whether an
# instance is serving.
#
# 15s interval keeps each individual prober well under the application's own
# 40-per-minute limit, which applies to /log_in like any other route.
resource "google_compute_health_check" "web" {
  count = var.backend_mode == "gke" ? 1 : 0

  project             = var.project_id
  name                = "${var.prefix}-web-hc"
  check_interval_sec  = 15
  timeout_sec         = 5
  healthy_threshold   = 1
  unhealthy_threshold = 3

  http_health_check {
    request_path       = "/log_in"
    port_specification = "USE_SERVING_PORT"
  }

  log_config {
    enable = true
  }
}

resource "google_compute_backend_service" "web" {
  project = var.project_id
  name    = "${var.prefix}-web-backend"

  protocol = "HTTP"
  # A serverless NEG (Cloud Run) takes no named port and no backend timeout:
  # the request timeout is the Cloud Run service's own (3600 s).
  port_name             = var.backend_mode == "gke" ? "http" : null
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = var.backend_mode == "gke" ? 3600 : null
  # Absent, not empty, for a serverless NEG: the attribute takes one or more.
  health_checks   = var.backend_mode == "gke" ? google_compute_health_check.web[*].id : null
  security_policy = google_compute_security_policy.this.id

  custom_request_headers = ["X-Real-IP:{client_ip_address}"]

  # Zonal NEGs need an explicit balancing mode; a serverless NEG takes none.
  dynamic "backend" {
    for_each = data.google_compute_network_endpoint_group.web
    content {
      group                 = backend.value.id
      balancing_mode        = "RATE"
      max_rate_per_endpoint = 200
    }
  }

  dynamic "backend" {
    for_each = google_compute_region_network_endpoint_group.cloudrun
    content {
      group = backend.value.id
    }
  }

  connection_draining_timeout_sec = 60

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

###############################################################################
# Cloud Armor
#
# The WAF rules start in preview so a bad signature cannot lock everyone out of
# a freshly deployed system. Watch the preview verdicts in Cloud Logging, then
# flip preview to false.
###############################################################################

resource "google_compute_security_policy" "this" {
  project = var.project_id
  name    = "${var.prefix}-armor"

  # The uptime check: Google's probers come from addresses web_allowed_cidrs
  # does not list, so they are recognised by a header only Terraform and the
  # check know. Without this the uptime alert fires for good.
  rule {
    priority    = 900
    action      = "allow"
    description = "Uptime check (X-ScanSuite-Uptime)"

    match {
      expr {
        expression = "request.headers['x-scansuite-uptime'] == '${var.uptime_token}'"
      }
    }
  }

  # With web_allowed_cidrs set, only those ranges match here, and everyone else
  # falls through to the default rule, which then denies. (A throttle rule that
  # conforms allows the request, so it has to carry the allowlist itself.)
  rule {
    priority    = 1000
    action      = "throttle"
    description = "Coarse per-IP rate limit. The application enforces a tighter one itself."

    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = length(var.web_allowed_cidrs) > 0 ? var.web_allowed_cidrs : ["*"]
      }
    }

    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"

      rate_limit_threshold {
        count        = 600
        interval_sec = 60
      }
    }
  }

  rule {
    priority    = 1100
    action      = "deny(403)"
    preview     = true
    description = "OWASP SQL injection"

    match {
      expr {
        expression = "evaluatePreconfiguredExpr('sqli-v33-stable')"
      }
    }
  }

  rule {
    priority    = 1200
    action      = "deny(403)"
    preview     = true
    description = "OWASP cross-site scripting"

    match {
      expr {
        expression = "evaluatePreconfiguredExpr('xss-v33-stable')"
      }
    }
  }

  rule {
    priority    = 1300
    action      = "deny(403)"
    preview     = true
    description = "OWASP local file inclusion"

    match {
      expr {
        expression = "evaluatePreconfiguredExpr('lfi-v33-stable')"
      }
    }
  }

  rule {
    priority    = 2147483647
    action      = length(var.web_allowed_cidrs) > 0 ? "deny(403)" : "allow"
    description = length(var.web_allowed_cidrs) > 0 ? "Default: not in web_allowed_cidrs" : "Default"

    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }

  adaptive_protection_config {
    layer_7_ddos_defense_config {
      enable = true
    }
  }
}

###############################################################################
# Routing
###############################################################################

resource "google_compute_url_map" "https" {
  project         = var.project_id
  name            = "${var.prefix}-urlmap"
  default_service = google_compute_backend_service.web.id

}

resource "google_compute_url_map" "http_redirect" {
  project = var.project_id
  name    = "${var.prefix}-urlmap-redirect"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

###############################################################################
# Certificates
#
# With no domain name the deployment still comes up on HTTPS, using a
# self-signed certificate issued for the load balancer's own IP. Browsers warn;
# nothing else breaks, and it needs no DNS. Set domain_name to switch to a
# Google-managed certificate, which provisions once the name resolves here.
###############################################################################

resource "tls_private_key" "self_signed" {
  count = var.domain_name == "" ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "self_signed" {
  count = var.domain_name == "" ? 1 : 0

  private_key_pem = tls_private_key.self_signed[0].private_key_pem
  ip_addresses    = [google_compute_global_address.lb.address]

  validity_period_hours = 26280 # 3 years
  early_renewal_hours   = 720

  allowed_uses = ["key_encipherment", "digital_signature", "server_auth"]

  subject {
    common_name  = google_compute_global_address.lb.address
    organization = "ScanSuite"
  }
}

resource "google_compute_ssl_certificate" "self_signed" {
  count = var.domain_name == "" ? 1 : 0

  project     = var.project_id
  name_prefix = "${var.prefix}-selfsigned-"
  private_key = tls_private_key.self_signed[0].private_key_pem
  certificate = tls_self_signed_cert.self_signed[0].cert_pem

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_managed_ssl_certificate" "managed" {
  count = var.domain_name != "" ? 1 : 0

  project = var.project_id
  name    = "${var.prefix}-managed-cert"

  managed {
    domains = [var.domain_name]
  }

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Front end
###############################################################################

resource "google_compute_target_https_proxy" "this" {
  project = var.project_id
  name    = "${var.prefix}-https-proxy"
  url_map = google_compute_url_map.https.id

  # Exactly one of the two exists, so concatenating the splats yields a
  # single-element list without indexing into an empty one.
  ssl_certificates = concat(
    google_compute_managed_ssl_certificate.managed[*].id,
    google_compute_ssl_certificate.self_signed[*].id,
  )
}

resource "google_compute_target_http_proxy" "redirect" {
  project = var.project_id
  name    = "${var.prefix}-http-proxy"
  url_map = google_compute_url_map.http_redirect.id
}

resource "google_compute_global_forwarding_rule" "https" {
  project               = var.project_id
  name                  = "${var.prefix}-https"
  target                = google_compute_target_https_proxy.this.id
  ip_address            = google_compute_global_address.lb.id
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

resource "google_compute_global_forwarding_rule" "http" {
  project               = var.project_id
  name                  = "${var.prefix}-http"
  target                = google_compute_target_http_proxy.redirect.id
  ip_address            = google_compute_global_address.lb.id
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

###############################################################################
# DNS (optional)
#
# Creating the zone is automatable; delegating it at your registrar is not.
###############################################################################

resource "google_dns_managed_zone" "this" {
  count = var.manage_dns && var.domain_name != "" ? 1 : 0

  project     = var.project_id
  name        = "${var.prefix}-zone"
  dns_name    = "${var.domain_name}."
  description = "ScanSuite"
}

resource "google_dns_record_set" "a" {
  count = var.manage_dns && var.domain_name != "" ? 1 : 0

  project      = var.project_id
  managed_zone = google_dns_managed_zone.this[0].name
  name         = "${var.domain_name}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.lb.address]
}
