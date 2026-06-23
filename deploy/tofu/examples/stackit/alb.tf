# ── TLS Certificate (tls_mode = "alb") ────────────────────────────────────────
# Stored in Stackit ALB Certificate Service.
# Operator obtains the certificate externally (e.g. via certbot with DNS-01 on the
# external domain hoster) and provides tls_certificate_pem + tls_private_key_pem.

resource "stackit_alb_certificate" "nebu" {
  count       = var.tls_mode == "alb" ? 1 : 0
  project_id  = var.stackit_project_id
  name        = "nebu-${var.environment}-cert"
  public_key  = file(var.tls_certificate_pem)
  private_key = file(var.tls_private_key_pem)
}

# ── Application Load Balancer (tls_mode = "alb") ──────────────────────────────
# L7 ALB with TLS termination at the load balancer.
# go-removal-cleanup: targets the Docker Compose nginx proxy on the VM (port 80),
# which forwards to the server container (Bandit listener, container port 4000).
# Port 443 HTTPS → VM:80 (nginx proxy → server:4000)
# Port 80  HTTP  → VM:80 (nginx proxy → server:4000)

resource "stackit_application_load_balancer" "nebu" {
  count            = var.tls_mode == "alb" ? 1 : 0
  project_id       = var.stackit_project_id
  name             = "nebu-${var.environment}-alb"
  plan_id          = var.alb_plan_id
  external_address = stackit_public_ip.nebu-alb.ip

  networks = [
    {
      network_id = stackit_network.nebu.network_id
      role       = "ROLE_LISTENERS_AND_TARGETS"
    }
  ]

  target_pools = [
    {
      name        = "matrix-api"
      target_port = 80
      targets = [
        {
          display_name = stackit_server.nebu.name
          ip           = stackit_network_interface.nebu.ipv4
        }
      ]
      active_health_check = {
        interval            = "10s"
        interval_jitter     = "3s"
        timeout             = "5s"
        healthy_threshold   = 3
        unhealthy_threshold = 3
        http_health_checks = {
          ok_status = ["200"]
          path      = "/_matrix/client/versions"
        }
      }
    }
  ]

  listeners = [
    {
      name     = "https-443"
      port     = 443
      protocol = "PROTOCOL_HTTPS"
      http = {
        hosts = [{
          host = var.server_name
          rules = [{
            target_pool = "matrix-api"
            web_socket  = true
            path = {
              prefix = "/"
            }
          }]
        }]
      }
      https = {
        certificate_config = {
          certificate_ids = [stackit_alb_certificate.nebu[0].cert_id]
        }
      }
    },
    {
      name     = "http-80"
      port     = 80
      protocol = "PROTOCOL_HTTP"
      http = {
        hosts = [{
          host = var.server_name
          rules = [{
            target_pool = "matrix-api"
            web_socket  = false
            path = {
              prefix = "/"
            }
          }]
        }]
      }
    }
  ]

  options = {
    private_network_only = false
    acl                  = ["0.0.0.0/0"]
  }
}

# ── Network Load Balancer / TCP passthrough (tls_mode = "none" | "acme") ──────
# go-removal-cleanup: server publishes host port 8008 (mapped to its container port
# 4000) and serves the public Matrix CS API + media + admin directly.
# tls_mode = "none": port 443 → server host port 8008 (direct, no TLS)
# tls_mode = "acme": port 443 → nginx:443 (TLS termination) + port 80 → nginx:80 (HTTP redirect)

locals {
  _nlb_vm_targets = [
    {
      display_name = stackit_server.nebu.name
      ip           = stackit_network_interface.nebu.ipv4
    },
  ]

  _nlb_health_check = {
    healthy_threshold   = 3
    interval            = "10s"
    interval_jitter     = "3s"
    timeout             = "5s"
    unhealthy_threshold = 3
  }

  nlb_listeners = concat(
    [
      {
        display_name = "https-443"
        port         = 443
        protocol     = "PROTOCOL_TCP"
        target_pool  = "matrix-api"
      },
    ],
    var.tls_mode == "acme" ? [
      {
        display_name = "http-80"
        port         = 80
        protocol     = "PROTOCOL_TCP"
        target_pool  = "http-redirect"
      },
    ] : []
  )

  nlb_target_pools = concat(
    [
      {
        name                = "matrix-api"
        target_port         = var.tls_mode == "acme" ? 443 : 8008
        targets             = local._nlb_vm_targets
        active_health_check = local._nlb_health_check
      },
    ],
    var.tls_mode == "acme" ? [
      {
        name                = "http-redirect"
        target_port         = 80
        targets             = local._nlb_vm_targets
        active_health_check = local._nlb_health_check
      },
    ] : []
  )
}

resource "stackit_loadbalancer" "nebu" {
  count            = var.tls_mode != "alb" ? 1 : 0
  project_id       = var.stackit_project_id
  name             = "nebu-${var.environment}-alb"
  plan_id          = var.alb_plan_id
  external_address = stackit_public_ip.nebu-alb.ip

  networks = [
    {
      network_id = stackit_network.nebu.network_id
      role       = "ROLE_LISTENERS_AND_TARGETS"
    },
  ]

  listeners    = local.nlb_listeners
  target_pools = local.nlb_target_pools

  options = {
    private_network_only = false
  }
}


# ── Floating IP ───────────────────────────────────────────────────────────────

resource "stackit_public_ip" "nebu-alb" {
  project_id           = var.stackit_project_id
  network_interface_id = stackit_network_interface.nebu.network_interface_id
}
