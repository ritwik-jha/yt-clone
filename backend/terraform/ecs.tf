# Backend compute: one ECS cluster, two services from the same image.
#
#   api     ECS Express Mode service. Express Mode owns the internet-facing
#           ALB (HTTPS on 443 with an AWS-issued cert and *.on.aws URL),
#           target group, listener rule, autoscaling, and its own SGs.
#   poller  Plain Fargate service, no load balancer. Single consumer of the
#           completion queue; SQS redelivery covers task restarts.
#
# Config arrives as task environment built from both stacks' state — there is
# no .env on the servers. The Cognito client secret is injected from SSM by
# the API's execution role. The database password never reaches the task
# definition: both task roles read it from the RDS-managed secret at runtime.

resource "aws_ecs_cluster" "backend" {
  name = var.backend_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

locals {
  # Both processes connect as the RDS master user. RDS enforces TLS
  # (rds.force_ssl defaults on from PostgreSQL 15).
  db_environment = {
    DB_HOST       = aws_db_instance.main.address
    DB_PORT       = tostring(aws_db_instance.main.port)
    DB_NAME       = aws_db_instance.main.db_name
    DB_USER       = aws_db_instance.main.username
    DB_SECRET_ARN = aws_db_instance.main.master_user_secret[0].secret_arn
    DB_SSLMODE    = "require"
  }

  api_environment = merge(local.db_environment, {
    AWS_REGION                   = var.aws_region
    APP_PORT                     = tostring(var.api_port)
    CORS_ORIGINS                 = join(",", var.cors_origins)
    ACCESS_COOKIE_MAX_AGE        = tostring(var.access_cookie_max_age)
    REFRESH_COOKIE_MAX_AGE       = tostring(var.refresh_cookie_max_age)
    COOKIE_SECURE                = tostring(var.cookie_secure)
    COOKIE_SAMESITE              = var.cookie_samesite
    COGNITO_USER_POOL_ID         = local.pipeline.cognito_user_pool_id
    COGNITO_CLIENT_ID            = local.pipeline.cognito_user_pool_client_id
    DB_POOL_SIZE                 = tostring(var.api_db_pool_size)
    DB_MAX_OVERFLOW              = tostring(var.api_db_max_overflow)
    S3_RAW_VIDEOS_BUCKET         = local.pipeline.raw_bucket
    S3_THUMBNAILS_BUCKET         = aws_s3_bucket.thumbnails.bucket
    S3_PROCESSED_BUCKET          = local.pipeline.processed_bucket
    PRESIGNED_URL_TTL_SECONDS    = tostring(var.presigned_url_ttl_seconds)
    CLOUDFRONT_DOMAIN            = local.pipeline.cloudfront_domain_name
    THUMBNAILS_CDN_DOMAIN        = aws_cloudfront_distribution.thumbnails.domain_name
    REDIS_HOST                   = local.pipeline.redis_host
    REDIS_PORT                   = tostring(local.pipeline.redis_port)
    REDIS_TLS                    = "1"
    REDIS_PROGRESS_PREFIX        = local.pipeline.redis_progress_key_prefix
    REDIS_META_PREFIX            = "video:meta"
    VIDEO_META_CACHE_TTL_SECONDS = tostring(var.video_meta_cache_ttl_seconds)
  })

  # The poller is single-threaded and uses one connection at a time.
  poller_environment = merge(local.db_environment, {
    AWS_REGION                   = var.aws_region
    DB_POOL_SIZE                 = "1"
    DB_MAX_OVERFLOW              = "0"
    COMPLETION_QUEUE_URL         = local.pipeline.completion_queue_url
    COMPLETION_POLL_WAIT_SECONDS = tostring(var.completion_poll_wait_seconds)
    COMPLETION_MAX_MESSAGES      = tostring(var.completion_max_messages)
  })
}

# ------------------------------------------------------------------- API

resource "aws_ecs_express_gateway_service" "api" {
  service_name            = "${var.backend_name}-api"
  cluster                 = aws_ecs_cluster.backend.name
  execution_role_arn      = aws_iam_role.api_execution.arn
  task_role_arn           = aws_iam_role.api_task.arn
  infrastructure_role_arn = aws_iam_role.express_infrastructure.arn

  cpu               = var.api_cpu
  memory            = var.api_memory
  health_check_path = "/healthz"

  primary_container {
    image          = local.backend_image
    container_port = var.api_port
    # Migrate, then serve. Tasks that start together queue on an advisory
    # lock in migrations/env.py, so only one applies each revision. Keep in
    # step with the Dockerfile CMD.
    command = [
      "sh", "-c",
      "alembic upgrade head && exec uvicorn app.main:app --host 0.0.0.0 --port ${var.api_port} --workers 2 --proxy-headers --forwarded-allow-ips '*'",
    ]

    aws_logs_configuration {
      log_group         = aws_cloudwatch_log_group.backend.name
      log_stream_prefix = "api"
    }

    dynamic "environment" {
      for_each = local.api_environment
      content {
        name  = environment.key
        value = environment.value
      }
    }

    secret {
      name       = "COGNITO_CLIENT_SECRET"
      value_from = local.pipeline.cognito_client_secret_parameter_arn
    }
  }

  # Public subnets: Express Mode creates an internet-facing ALB and assigns
  # public IPs to the tasks. Express Mode requires at least two subnets.
  network_configuration {
    subnets         = local.pipeline.public_subnet_ids
    security_groups = [aws_security_group.api.id]
  }

  scaling_target {
    min_task_count            = var.api_min_tasks
    max_task_count            = var.api_max_tasks
    auto_scaling_metric       = "AVERAGE_CPU"
    auto_scaling_target_value = var.api_cpu_target_percent
  }

  wait_for_steady_state = true

  # Keeps the roles alive until the service has drained on destroy; without
  # this the service can hang in DRAINING.
  depends_on = [
    aws_iam_role_policy.api_execution,
    aws_iam_role_policy.api_task,
    aws_iam_role_policy_attachment.express_infrastructure,
    aws_vpc_security_group_ingress_rule.api_from_vpc,
    aws_vpc_security_group_ingress_rule.redis_from_api,
    aws_vpc_security_group_ingress_rule.db_from_api,
  ]
}

# ---------------------------------------------------------------- poller

resource "aws_ecs_task_definition" "poller" {
  family                   = "${var.backend_name}-poller"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.poller_cpu
  memory                   = var.poller_memory
  execution_role_arn       = aws_iam_role.poller_execution.arn
  task_role_arn            = aws_iam_role.poller_task.arn

  # Pinned to match the API: the AWS provider does not yet expose an
  # architecture setting for Express Mode services, which run x86_64, and
  # both services share one single-arch image.
  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name      = "poller"
      image     = local.backend_image
      essential = true
      command   = ["python", "-m", "app.workers.completion_poller"]
      environment = [
        for k, v in local.poller_environment : { name = k, value = v }
      ]
      # The worker traps SIGTERM and finishes its in-flight batch.
      stopTimeout = 30
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.backend.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "poller"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "poller" {
  name            = "${var.backend_name}-poller"
  cluster         = aws_ecs_cluster.backend.id
  task_definition = aws_ecs_task_definition.poller.arn
  desired_count   = var.poller_desired_count
  launch_type     = "FARGATE"

  # A brief overlap of two pollers during a deploy is harmless: every status
  # UPDATE is guarded and idempotent, and SQS hides in-flight messages from
  # the second consumer.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = local.pipeline.public_subnet_ids
    security_groups  = [aws_security_group.poller.id]
    assign_public_ip = true
  }

  depends_on = [
    aws_iam_role_policy.poller_execution,
    aws_iam_role_policy.poller_task,
    aws_vpc_security_group_ingress_rule.db_from_poller,
  ]
}
