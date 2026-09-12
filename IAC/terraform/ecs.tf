resource "aws_cloudwatch_log_group" "transcoder" {
  name              = "/ecs/${var.ecs_task_family}"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "this" {
  name = var.ecs_cluster_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_task_definition" "transcoder" {
  family                   = var.ecs_task_family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  runtime_platform {
    cpu_architecture        = var.cpu_architecture
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name      = var.container_name
      image     = local.image_uri
      essential = true
      environment = [
        { name = "S3_BUCKET",              value = var.raw_bucket_name },
        { name = "S3_KEY",                 value = "default.mp4" },
        { name = "PROCESSED_BUCKET",       value = var.processed_bucket_name },
        { name = "COMPLETION_QUEUE_URL",   value = aws_sqs_queue.completion.url },
        { name = "REDIS_HOST",             value = local.redis_address },
        { name = "REDIS_PORT",             value = tostring(local.redis_port) },
        { name = "REDIS_TLS",              value = "1" },
        { name = "REDIS_LOCK_PREFIX",      value = var.redis_lock_key_prefix },
        { name = "REDIS_PROGRESS_PREFIX",  value = var.redis_progress_key_prefix },
        { name = "REDIS_LOCK_TTL_SECONDS", value = tostring(var.redis_lock_ttl_seconds) },
        { name = "AWS_REGION",             value = var.aws_region }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.transcoder.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "transcoder"
        }
      }
    }
  ])
}
