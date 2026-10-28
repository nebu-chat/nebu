# nebu-aws: Application Load Balancer — internet-facing, HTTPS-only, HTTP redirect.

# ── Application Load Balancer ────────────────────────────────────────────────

resource "aws_lb" "this" {
  name               = "nebu-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  # Enforce HTTPS: drop_invalid_header_fields prevents header injection attacks.
  drop_invalid_header_fields = true

  tags = merge(var.common_tags, {
    Name = "nebu-${var.environment}-alb"
  })
}

# ── Target Group: server (port 4000) ──────────────────────────────────────────
# go-removal-cleanup: the gateway target group (port 8008) was removed. The
# Elixir server now serves the public Matrix CS API, /_matrix/media, and the admin
# LiveView on its Bandit HTTP listener (container port 4000) — it is the ALB target.

resource "aws_lb_target_group" "server" {
  name        = "nebu-${var.environment}-server-tg"
  port        = 4000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"

  # Target-group health = traffic readiness, so it probes the Matrix versions endpoint. The
  # unauthenticated, dependency-free /health also exists (used for the container/Helm liveness probe).
  health_check {
    enabled             = true
    path                = "/_matrix/client/versions"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = merge(var.common_tags, {
    Name = "nebu-${var.environment}-server-tg"
  })
}

# ── Listener: port 443 (HTTPS → server target group) ──────────────────────────

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.server.arn
  }

  tags = merge(var.common_tags, {
    Name = "nebu-${var.environment}-https-listener"
  })
}

# ── Listener: port 80 (HTTP → HTTPS redirect) ────────────────────────────────

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = merge(var.common_tags, {
    Name = "nebu-${var.environment}-http-redirect-listener"
  })
}
