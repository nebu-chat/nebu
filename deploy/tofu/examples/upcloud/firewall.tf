# ── Firewall Rules ─────────────────────────────────────────────────────────────
# UpCloud firewall rules are attached directly to a server (not a reusable group).
# Rules are evaluated top-to-bottom; all unmatched inbound traffic is dropped by default.
#
# NOTE: UpCloud trial accounts enforce a built-in firewall (TRIAL_FIREWALL) that
# cannot be overridden. Set enable_firewall = false in tfvars when on a trial account.

resource "upcloud_firewall_rules" "nebu" {
  count     = var.enable_firewall ? 1 : 0
  server_id = upcloud_server.nebu.id

  # Inbound: SSH from anywhere (restrict to a bastion CIDR in production)
  firewall_rule {
    action                 = "accept"
    direction              = "in"
    protocol               = "tcp"
    destination_port_start = "22"
    destination_port_end   = "22"
    comment                = "SSH"
  }

  # Inbound: HTTPS from anywhere
  firewall_rule {
    action                 = "accept"
    direction              = "in"
    protocol               = "tcp"
    destination_port_start = "443"
    destination_port_end   = "443"
    comment                = "HTTPS"
  }

  # Inbound: HTTP (port 80) for HTTP→HTTPS redirect.
  # tls_mode = "acme": nginx handles the redirect (and certbot HTTP-01).
  # tls_mode = "alb" / "dynamic": the LB redirects; VM nginx :80 only redirects + answers the LB probe.
  dynamic "firewall_rule" {
    for_each = var.tls_mode != "none" ? [1] : []
    content {
      action                 = "accept"
      direction              = "in"
      protocol               = "tcp"
      destination_port_start = "80"
      destination_port_end   = "80"
      comment                = "HTTP (redirect or LB probe)"
    }
  }

  # Inbound: nginx realip/TLS-terminated listener (:8081) from the private network only
  # (tls_mode = "alb" / "dynamic"). Only the LB lives there; the public side is never opened.
  dynamic "firewall_rule" {
    for_each = contains(["alb", "dynamic"], var.tls_mode) ? [1] : []
    content {
      action                 = "accept"
      direction              = "in"
      protocol               = "tcp"
      source_address_start   = cidrhost(var.network_cidr, 0)
      source_address_end     = cidrhost(var.network_cidr, -1)
      destination_port_start = "8081"
      destination_port_end   = "8081"
      comment                = "nginx proxy :8081 (LB → VM, private network only)"
    }
  }

  # Inbound: Matrix API port from LB → VM.
  # tls_mode = "none": LB targets server host port 8008 directly.
  # tls_mode = "acme" | "alb": port 8008 stays internal (nginx proxy in front).
  dynamic "firewall_rule" {
    for_each = var.tls_mode == "none" ? [1] : []
    content {
      action                 = "accept"
      direction              = "in"
      protocol               = "tcp"
      destination_port_start = "8008"
      destination_port_end   = "8008"
      comment                = "Matrix API (LB → VM, tls_mode = none)"
    }
  }

  # Inbound: Dex OIDC port (dex mode only, tls_mode = "none" only).
  # tls_mode = "acme": nginx proxies /dex/ → localhost:5556, port stays internal.
  # tls_mode = "alb":  Docker Compose nginx routes /dex/ → dex:5556, port stays internal.
  # tls_mode = "none": browser follows OIDC redirects directly to port 5556.
  dynamic "firewall_rule" {
    for_each = var.oidc_mode == "dex" && var.tls_mode == "none" ? [1] : []
    content {
      action                 = "accept"
      direction              = "in"
      protocol               = "tcp"
      source_address_start   = cidrhost(var.dex_allowed_cidr, 0)
      source_address_end     = cidrhost(var.dex_allowed_cidr, -1)
      destination_port_start = "5556"
      destination_port_end   = "5556"
      comment                = "Dex OIDC (tls_mode = none, dex mode)"
    }
  }

  # Outbound: allow all
  firewall_rule {
    action    = "accept"
    direction = "out"
    comment   = "Allow all outbound"
  }

  # Default: drop all other inbound traffic
  firewall_rule {
    action    = "drop"
    direction = "in"
    comment   = "Drop all other inbound"
  }
}
