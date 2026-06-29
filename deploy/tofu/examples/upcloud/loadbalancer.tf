# ── TLS Certificate (tls_mode = "dynamic") ────────────────────────────────────
# UpCloud provisions and renews the Let's Encrypt certificate automatically.
# HTTP-01 challenge is handled by the LB itself — no certbot on the VM needed.
# Requires acme_email and a DNS record pointing to the LB before tofu apply.

resource "upcloud_loadbalancer_dynamic_certificate_bundle" "nebu" {
  count     = var.tls_mode == "dynamic" ? 1 : 0
  name      = "nebu-${var.environment}-cert"
  hostnames = [var.server_name]
  key_type  = "rsa"
}

# ── TLS Certificate (tls_mode = "alb") ────────────────────────────────────────
# Manually managed certificate — operator provides PEM files.
# Use when you need a custom CA, a wildcard cert, or a cert from a specific CA.
# Prefer tls_mode = "dynamic" for standard deployments (automatic renewal).

resource "upcloud_loadbalancer_manual_certificate_bundle" "nebu" {
  count       = var.tls_mode == "alb" ? 1 : 0
  name        = "nebu-${var.environment}-cert-manual"
  certificate = filebase64(var.tls_certificate_pem)
  private_key = filebase64(var.tls_private_key_pem)
}

# ── Load Balancer ─────────────────────────────────────────────────────────────
# L4/L7 load balancer with TCP passthrough (tls_mode = "none" / "acme") or
# HTTP with TLS termination at LB (tls_mode = "dynamic" / "alb").
#
# The LB is attached to the private network and receives a public DNS name
# (dns_name output) that can be used for CNAME records or direct A-record lookups.

resource "upcloud_loadbalancer" "nebu" {
  configured_status = "started"
  name              = "nebu-${var.environment}-lb"
  plan              = var.lb_plan
  zone              = var.zone

  networks {
    name   = "public"
    type   = "public"
    family = "IPv4"
  }

  networks {
    name    = "private"
    type    = "private"
    family  = "IPv4"
    network = upcloud_network.nebu.id
  }
}

# ── Backend: HTTPS / Matrix API ───────────────────────────────────────────────

resource "upcloud_loadbalancer_backend" "nebu" {
  loadbalancer = upcloud_loadbalancer.nebu.id
  name         = "matrix-api"

  properties {
    health_check_type            = "http"
    health_check_url             = "/_matrix/client/versions"
    health_check_expected_status = 200
    health_check_interval        = 10
    health_check_fall            = 3
    health_check_rise            = 3
  }
}

resource "upcloud_loadbalancer_static_backend_member" "nebu" {
  backend = upcloud_loadbalancer_backend.nebu.id
  name    = "nebu-server"
  # Use the VM's private network interface IP.
  ip = [for ni in upcloud_server.nebu.network_interface : ni.ip_address if ni.type == "private"][0]
  # tls_mode = "none":             target port 8008 (server container, direct).
  # tls_mode = "acme":             target port 443  (nginx on VM, TLS termination).
  # tls_mode = "alb" / "dynamic":  target port 80   (Docker Compose nginx proxy → server:4000).
  port         = var.tls_mode == "acme" ? 443 : (contains(["alb", "dynamic"], var.tls_mode) ? 80 : 8008)
  weight       = 1
  max_sessions = 1000
  enabled      = true
}

# ── Frontend: HTTPS 443 ───────────────────────────────────────────────────────
# tls_mode = "dynamic" / "alb":  HTTP mode with TLS termination at the LB.
# tls_mode = "acme" / "none":    TCP passthrough to the VM.

resource "upcloud_loadbalancer_frontend" "https" {
  loadbalancer         = upcloud_loadbalancer.nebu.id
  name                 = "https-443"
  mode                 = contains(["alb", "dynamic"], var.tls_mode) ? "http" : "tcp"
  port                 = 443
  default_backend_name = upcloud_loadbalancer_backend.nebu.name

  networks {
    name = "public"
  }
}

# TLS config is a separate resource — the frontend's tls_configs attribute is read-only.
resource "upcloud_loadbalancer_frontend_tls_config" "https" {
  count    = contains(["alb", "dynamic"], var.tls_mode) ? 1 : 0
  frontend = upcloud_loadbalancer_frontend.https.id
  name     = "nebu-tls"
  certificate_bundle = var.tls_mode == "dynamic" ? (
    upcloud_loadbalancer_dynamic_certificate_bundle.nebu[0].id
    ) : (
    upcloud_loadbalancer_manual_certificate_bundle.nebu[0].id
  )
}

# ── Backend: HTTP 80 (tls_mode != "none") ────────────────────────────────────

resource "upcloud_loadbalancer_backend" "nebu_http" {
  count        = var.tls_mode != "none" ? 1 : 0
  loadbalancer = upcloud_loadbalancer.nebu.id
  name         = "http-redirect"

  properties {
    health_check_type     = "tcp"
    health_check_interval = 10
    health_check_fall     = 3
    health_check_rise     = 3
  }
}

resource "upcloud_loadbalancer_static_backend_member" "nebu_http" {
  count        = var.tls_mode != "none" ? 1 : 0
  backend      = upcloud_loadbalancer_backend.nebu_http[0].id
  name         = "nebu-server-http"
  ip           = [for ni in upcloud_server.nebu.network_interface : ni.ip_address if ni.type == "private"][0]
  port         = 80
  weight       = 1
  max_sessions = 1000
  enabled      = true
}

# ── Frontend: HTTP 80 (tls_mode != "none") ───────────────────────────────────
# tls_mode = "acme":             TCP passthrough → nginx:80 (301 HTTP→HTTPS redirect).
# tls_mode = "dynamic" / "alb":  TCP passthrough → VM:80 (Docker Compose nginx proxy → server:4000).
#                                 For "dynamic": UpCloud intercepts .well-known/acme-challenge/* at LB.

resource "upcloud_loadbalancer_frontend" "http" {
  count                = var.tls_mode != "none" ? 1 : 0
  loadbalancer         = upcloud_loadbalancer.nebu.id
  name                 = "http-80"
  mode                 = "tcp"
  port                 = 80
  default_backend_name = upcloud_loadbalancer_backend.nebu_http[0].name

  networks {
    name = "public"
  }
}
