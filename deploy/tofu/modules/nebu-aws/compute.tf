# nebu-aws: ECS Fargate cluster, IAM task execution role, task definitions, and ECS services.

# ── ECS Cluster ──────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "this" {
  name = "nebu-${var.environment}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(var.common_tags, {
    Name = "nebu-${var.environment}-ecs-cluster"
  })
}

# ── IAM: ECS Task Execution Role ─────────────────────────────────────────────

resource "aws_iam_role" "ecs_task_execution" {
  name        = "nebu-${var.environment}-ecs-task-execution-role"
  description = "IAM role assumed by ECS to pull container images and read Secrets Manager secrets."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name = "nebu-${var.environment}-ecs-task-execution-role"
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Inline policy: allow reading Secrets Manager secrets scoped to nebu/{environment}/*.
# Least-privilege: only the secrets this module provisions under nebu/{environment}/ are accessible.
# NOTE: kms:Decrypt is omitted here. If your secrets use a customer-managed KMS key (CMK),
# add kms:Decrypt with the CMK ARN to this policy — without it ECS cannot decrypt CMK-encrypted secrets.
resource "aws_iam_role_policy" "ecs_task_execution_secrets" {
  name = "nebu-${var.environment}-ecs-secrets-read"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadNebuSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:*:*:secret:nebu/${var.environment}/*"
      }
    ]
  })
}

# ── CloudWatch Log Groups for ECS tasks ─────────────────────────────────────
# go-removal-cleanup: the Go gateway log group was removed. The Elixir server is now
# the single application container — it serves the public Matrix CS API, the
# /_matrix/media endpoints, and the Phoenix LiveView admin on its Bandit listener.

resource "aws_cloudwatch_log_group" "server" {
  name              = "/ecs/nebu-${var.environment}-server"
  retention_in_days = 30

  tags = merge(var.common_tags, {
    Name = "nebu-${var.environment}-server-logs"
  })
}

# ── ECS Task Definition: server ──────────────────────────────────────────────
# go-removal-cleanup: the separate Go gateway task definition was removed. The
# Elixir server is now the single application container — it serves the public
# Matrix CS API, the /_matrix/media endpoints, and the Phoenix LiveView admin on
# its Bandit HTTP listener (container port 4000), plus gRPC on 9000 (internal).

resource "aws_ecs_task_definition" "server" {
  family                   = "nebu-${var.environment}-server"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  depends_on = [aws_cloudwatch_log_group.server]

  container_definitions = jsonencode([
    {
      name      = "server"
      image     = "${var.image_registry}/nebu-server:${var.nebu_version}"
      essential = true

      portMappings = [
        {
          # Public HTTP listener (Matrix CS API + /_matrix/media + admin LiveView).
          containerPort = 4000
          protocol      = "tcp"
        },
        {
          # gRPC (internal cluster communication only).
          containerPort = 9000
          protocol      = "tcp"
        }
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "wget -qO- http://localhost:4000/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 90
      }

      # All runtime credentials sourced from Secrets Manager — never plaintext.
      # Server now serves the public Matrix API + admin, so it needs the OIDC config
      # that previously lived on the gateway task.
      secrets = [
        {
          name      = "DATABASE_URL"
          valueFrom = aws_secretsmanager_secret.db_url.arn
        },
        {
          name      = "RELEASE_COOKIE"
          valueFrom = aws_secretsmanager_secret.release_cookie.arn
        },
        {
          name      = "NEBU_INTERNAL_SECRET"
          valueFrom = aws_secretsmanager_secret.nebu_internal_secret.arn
        },
        {
          name      = "NEBU_OIDC_ISSUER"
          valueFrom = aws_secretsmanager_secret.oidc_issuer.arn
        },
        {
          name      = "NEBU_ADMIN_OIDC_CLIENT_SECRET"
          valueFrom = aws_secretsmanager_secret.oidc_client_secret.arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = "/ecs/nebu-${var.environment}-server"
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "server"
        }
      }
    }
  ])

  tags = merge(var.common_tags, {
    Name = "nebu-${var.environment}-server-task"
  })
}

# ── ECS Service: server ───────────────────────────────────────────────────────
# go-removal-cleanup: the separate gateway ECS service was removed. The server
# service is now the ALB target — the ALB forwards public traffic to server:4000.

resource "aws_ecs_service" "server" {
  name            = "nebu-${var.environment}-server"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.server.arn
  desired_count   = var.ecs_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.server.arn
    container_name   = "server"
    container_port   = 4000
  }

  # Allow ECS to update the service without tofu treating it as a drift.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [
    aws_lb_listener.https,
    aws_iam_role_policy_attachment.ecs_task_execution_managed,
  ]

  tags = merge(var.common_tags, {
    Name = "nebu-${var.environment}-server-service"
  })
}
