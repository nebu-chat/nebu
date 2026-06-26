# ── OIDC / TLS locals ────────────────────────────────────────────────────────
#
# tls_mode = "acme": certbot provisions a Let's Encrypt cert on first boot via
# HTTP-01 challenge. nginx proxies /dex/ → localhost:5556 when oidc_mode = "dex".
# Dex's issuer becomes https://<server_name>/dex (path-based routing via nginx).
# tls_mode = "alb": TLS terminated at the Stackit ALB — no nginx on the VM.
# tls_mode = "none": Dex is reached directly on port 5556 (plain HTTP).

locals {
  tls_enabled           = var.tls_mode != "none"
  dex_issuer            = local.tls_enabled ? "https://${var.server_name}/dex" : "http://${var.server_name}:5556/dex"
  effective_oidc_issuer = var.oidc_mode == "dex" ? local.dex_issuer : var.oidc_issuer

  # URL scheme + optional port suffix for redirect URIs injected into Dex's staticClients.
  gateway_scheme = local.tls_enabled ? "https" : "http"
  gateway_port   = local.tls_enabled ? "" : ":8008"

  # Logs — hostname extracted from Stackit Logs ingest_url (empty when enable_logs = false).
  logs_ingest_host = try(regex("https://([^/]+)", stackit_logs_instance.nebu[0].ingest_url)[0], "")
}

# ── SSH Key Pair ──────────────────────────────────────────────────────────────

resource "stackit_key_pair" "nebu" {
  # Note: stackit_key_pair is a global (account-level) resource; project_id is not supported.
  name       = "nebu-${var.environment}"
  public_key = var.ssh_public_key
}

# ── VM ────────────────────────────────────────────────────────────────────────
# Ubuntu 24.04 LTS — image ID for eu01 region.
# Update this ID if deploying to a different region (check STACKIT image catalog).
# Machine type g2i.2 = 4 vCPU / 8 GB RAM.
#
# SECURITY NOTE: cloud-init template including secrets is stored in Terraform state.
# Use encrypted state backend (Stackit Object Storage with server-side encryption) in production.
# The stackit_postgresflex_user.nebu.password is stored in state — ensure state encryption is enabled.
# Never commit .tfstate files. See the backend "s3" block in main.tf for the recommended configuration.
#
# go-removal-cleanup: server is the single application container. It serves the
# public Matrix CS API + /_matrix/media + admin on its Bandit listener (container
# port 4000), published on host port 8008 (and 8080 for admin).
# Traffic flow when tls_mode = "none", oidc_mode = "dex":
#   Browser → NLB:443 (TCP passthrough) → server host port 8008 (→ container 4000)
#   Server OIDC discovery (hairpin): server → http://<server_name>:5556/dex (host IP → Dex container)
#   Browser OIDC redirect: browser → http://<server_name>:5556/dex/auth (SG port 5556 open)
# Traffic flow when tls_mode = "acme":
#   Browser → NLB:443 (TCP passthrough) → VM:443 (nginx, TLS termination) → localhost:8008 (server)
#   Browser → NLB:80  (TCP passthrough) → VM:80  (nginx, 301 → https://<server_name>)
#   When oidc_mode = "dex": nginx also proxies /dex/ → localhost:5556 (Dex, plain HTTP on loopback)
# Traffic flow when tls_mode = "alb":
#   Browser → ALB:443 (HTTPS, TLS terminated at ALB) → VM:80 (Docker nginx proxy) → server:4000
#   Browser → ALB:80  (HTTP) → VM:80 (Docker nginx proxy) → server:4000

# ── Network Interface ─────────────────────────────────────────────────────────

resource "stackit_network_interface" "nebu" {
  project_id         = var.stackit_project_id
  network_id         = stackit_network.nebu.network_id
  security_group_ids = [stackit_security_group.nebu.security_group_id]
}

# ── Floating IP ───────────────────────────────────────────────────────────────

# resource "stackit_public_ip" "nebu" {
#   project_id           = var.stackit_project_id
#   network_interface_id = stackit_network_interface.nebu.network_interface_id
#
# }


resource "stackit_server" "nebu" {
  project_id        = var.stackit_project_id
  name              = "nebu-${var.environment}"
  machine_type      = var.vm_plan_id
  availability_zone = var.availability_zone
  boot_volume = {
    size        = 64
    source_type = "image"
    # Ubuntu 24.04 LTS (eu01) — verify current ID in STACKIT portal before apply
    source_id             = var.ubuntu_image_id
    delete_on_termination = true
  }

  keypair_name = stackit_key_pair.nebu.name

  network_interfaces = [
    stackit_network_interface.nebu.network_interface_id,
  ]

  user_data = templatefile("${path.module}/cloud-init.tftpl", {
    internal_secret              = var.internal_secret
    oidc_client_secret           = var.oidc_client_secret != null ? var.oidc_client_secret : ""
    oidc_client_id               = var.oidc_client_id != null ? var.oidc_client_id : ""
    oidc_issuer                  = local.effective_oidc_issuer
    oidc_audience                = var.oidc_audience != "" ? var.oidc_audience : (var.oidc_client_id != null ? var.oidc_client_id : "")
    oidc_mode                    = var.oidc_mode
    dex_static_password_hash     = var.oidc_mode == "dex" ? var.dex_static_password_hash : ""
    dex_user1_password_hash      = var.oidc_mode == "dex" ? var.dex_user1_password_hash : null
    dex_user2_password_hash      = var.oidc_mode == "dex" ? var.dex_user2_password_hash : null
    dex_compliance_password_hash = var.oidc_mode == "dex" ? var.dex_compliance_password_hash : null
    server_name                  = var.server_name
    image_registry               = var.image_registry
    nebu_version                 = var.nebu_version
    # PostgresFlex connection details — runtime (nebu_app) and migration (nebu_migrate)
    pg_host             = stackit_postgresflex_user.nebu.host
    pg_port             = stackit_postgresflex_user.nebu.port
    pg_user             = stackit_postgresflex_user.nebu.username
    pg_password         = stackit_postgresflex_user.nebu.password
    pg_migrate_user     = stackit_postgresflex_user.nebu_migrate.username
    pg_migrate_password = stackit_postgresflex_user.nebu_migrate.password
    # TLS — mode controls nginx/certbot (acme) vs ALB termination (alb) vs none
    tls_mode       = var.tls_mode
    acme_email     = var.acme_email
    acme_staging   = var.acme_staging
    gateway_scheme = local.gateway_scheme
    gateway_port   = local.gateway_port
    # Logging — Fluent Bit ships nebu.service journal logs to Stackit Logs (Loki)
    pii_encryption_key = var.pii_encryption_key
    enable_logs        = var.enable_logs
    logs_ingest_host   = local.logs_ingest_host
    logs_bearer_token  = try(stackit_logs_access_token.nebu[0].access_token, "")
    environment        = var.environment
    # Container resource limits
    # go-removal-cleanup: gateway/media container limits removed — those containers
    # no longer exist. Server serves the public Matrix + media + admin.
    server_cpu_limit     = var.server_cpu_limit
    server_memory_limit  = var.server_memory_limit
    dex_cpu_limit        = var.dex_cpu_limit
    dex_memory_limit     = var.dex_memory_limit
    element_cpu_limit    = var.element_cpu_limit
    element_memory_limit = var.element_memory_limit
    # Element Web — optional Matrix client served at /
    enable_element_web = var.enable_element_web
    # Media object storage — StackIT Object Store. When enabled, server serves
    # /_matrix/media from the bucket (the standalone Go media container is gone).
    enable_media_gateway = var.enable_media_gateway
    s3_access_key        = var.s3_access_key
    s3_secret_key        = var.s3_secret_key
    s3_endpoint          = var.s3_endpoint
    s3_bucket            = var.s3_bucket
  })

  lifecycle {
    precondition {
      condition     = var.oidc_mode != "dex" || var.dex_static_password_hash != null
      error_message = "dex_static_password_hash is required when oidc_mode = 'dex'."
    }

    precondition {
      condition     = var.oidc_mode != "dex" || (var.oidc_client_id != null && var.oidc_client_secret != null)
      error_message = "oidc_client_id and oidc_client_secret are required when oidc_mode = 'dex'."
    }

    # CORS guard: Element Web needs a reverse proxy to share the same origin as the
    # Matrix API. tls_mode = "acme" uses system nginx; tls_mode = "alb" uses a Docker
    # Compose nginx proxy service. tls_mode = "none" has no proxy — different origins
    # (Element :7070 vs server :8008) cause CORS preflight failures.
    precondition {
      condition     = !var.enable_element_web || var.tls_mode != "none"
      error_message = "enable_element_web requires tls_mode = 'acme' or 'alb'. Without a reverse proxy, Element Web runs on port 7070 while server is on port 8008 — different origins cause CORS preflight failures for all Matrix API requests."
    }

    precondition {
      condition = !var.enable_media_gateway || (
        length(var.s3_access_key) > 0 &&
        length(var.s3_secret_key) > 0 &&
        length(var.s3_bucket) > 0 &&
        length(var.s3_endpoint) > 0
      )
      error_message = "s3_access_key, s3_secret_key, s3_bucket, and s3_endpoint are required when enable_media_gateway = true."
    }
  }
}
