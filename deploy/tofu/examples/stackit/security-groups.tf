# ── Security Group ────────────────────────────────────────────────────────────

resource "stackit_security_group" "nebu" {
  project_id = var.stackit_project_id
  name       = "nebu-${var.environment}-sg"
  stateful   = true
}

# Inbound: HTTPS from anywhere
resource "stackit_security_group_rule" "inbound_https" {
  project_id        = var.stackit_project_id
  security_group_id = stackit_security_group.nebu.security_group_id
  direction         = "ingress"
  protocol = {
    name = "tcp"
  }
  port_range = {
    min = 443
    max = 443
  }
}

# Inbound: HTTP (port 80) for HTTP→HTTPS redirect.
# tls_mode = "acme": nginx handles redirect.
# tls_mode = "alb": the ALB http-80 listener targets VM nginx :80, which only redirects to https
#   (and answers the ALB health probe).
resource "stackit_security_group_rule" "inbound_http" {
  count             = var.tls_mode != "none" ? 1 : 0
  project_id        = var.stackit_project_id
  security_group_id = stackit_security_group.nebu.security_group_id
  direction         = "ingress"
  protocol = {
    name = "tcp"
  }
  port_range = {
    min = 80
    max = 80
  }
}

# Inbound: nginx proxy :8081 (tls_mode = "alb"): the ALB's https-443 target port, the only nginx
# listener that may carry the realip directives. Restricted to the private network (the ALB sits in
# it with ROLE_LISTENERS_AND_TARGETS); never open to the internet.
resource "stackit_security_group_rule" "inbound_proxy_alb" {
  count             = var.tls_mode == "alb" ? 1 : 0
  project_id        = var.stackit_project_id
  security_group_id = stackit_security_group.nebu.security_group_id
  direction         = "ingress"
  ip_range          = var.network_cidr
  protocol = {
    name = "tcp"
  }
  port_range = {
    min = 8081
    max = 8081
  }
}

# Inbound: Matrix API port from LB → VM.
# go-removal-cleanup: server publishes host port 8008 (mapped to its container port
# 4000) and serves the public Matrix CS API + media + admin directly.
# tls_mode = "none": NLB targets server host port 8008 directly.
# tls_mode = "acme": NLB targets port 443 (nginx), 8008 stays internal. No rule needed.
# tls_mode = "alb": ALB targets nginx :8081 (rule above), server's published 8008 is not used as the
#   LB target. No rule needed.
resource "stackit_security_group_rule" "inbound_matrix" {
  count             = var.tls_mode == "none" ? 1 : 0
  project_id        = var.stackit_project_id
  security_group_id = stackit_security_group.nebu.security_group_id
  direction         = "ingress"
  protocol = {
    name = "tcp"
  }
  port_range = {
    min = 8008
    max = 8008
  }
}

# Inbound: Dex OIDC port (dex mode only, tls_mode = "none" only).
# tls_mode = "acme": nginx proxies /dex/ → localhost:5556, port 5556 stays internal.
# tls_mode = "alb":  the VM nginx proxy routes /dex/ → dex:5556, port 5556 stays internal.
# tls_mode = "none": browser follows OIDC redirects directly to port 5556.
# Restricted to dex_allowed_cidr (default 0.0.0.0/0 for demo; restrict in shared environments).
resource "stackit_security_group_rule" "inbound_dex" {
  count             = var.oidc_mode == "dex" && var.tls_mode == "none" ? 1 : 0
  project_id        = var.stackit_project_id
  security_group_id = stackit_security_group.nebu.security_group_id
  direction         = "ingress"
  ip_range          = var.dex_allowed_cidr
  protocol = {
    name = "tcp"
  }
  port_range = {
    min = 5556
    max = 5556
  }
}

# Inbound: SSH from anywhere (restrict to a bastion CIDR in production)
resource "stackit_security_group_rule" "inbound_ssh" {
  project_id        = var.stackit_project_id
  security_group_id = stackit_security_group.nebu.security_group_id
  direction         = "ingress"
  protocol = {
    name = "tcp"
  }
  port_range = {
    min = 22
    max = 22
  }
}

# Outbound: allow all
# resource "stackit_security_group_rule" "outbound_all" {
#   project_id        = var.stackit_project_id
#   security_group_id = stackit_security_group.nebu.security_group_id
#   direction         = "egress"
# }
