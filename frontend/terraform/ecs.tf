# The web app as an ECS Express Mode service in the backend's cluster.
# Express Mode gives it an internet-facing HTTPS ALB with an AWS-issued
# certificate and a *.on.aws URL. nginx serves the Flutter build and forwards
# /auth/, /video/, /upload/ and /healthz to the API, so the app and API share
# one origin: first-party SameSite=Lax cookies, no CORS on the API.
resource "aws_ecs_express_gateway_service" "frontend" {
  service_name            = var.frontend_name
  cluster                 = local.backend.ecs_cluster
  execution_role_arn      = aws_iam_role.execution.arn
  infrastructure_role_arn = aws_iam_role.express_infrastructure.arn

  cpu               = var.cpu
  memory            = var.memory
  health_check_path = "/_health"

  primary_container {
    image          = local.frontend_image
    container_port = var.container_port

    aws_logs_configuration {
      log_group         = aws_cloudwatch_log_group.frontend.name
      log_stream_prefix = "web"
    }

    environment {
      name  = "API_ORIGIN"
      value = local.api_origin
    }

    environment {
      name  = "API_HOST"
      value = local.api_host
    }
  }

  network_configuration {
    subnets         = local.pipeline.public_subnet_ids
    security_groups = [aws_security_group.frontend.id]
  }

  scaling_target {
    min_task_count            = var.min_tasks
    max_task_count            = var.max_tasks
    auto_scaling_metric       = "AVERAGE_CPU"
    auto_scaling_target_value = 60
  }

  wait_for_steady_state = true

  depends_on = [
    aws_iam_role_policy.execution,
    aws_iam_role_policy_attachment.express_infrastructure,
    aws_vpc_security_group_ingress_rule.frontend_from_vpc,
  ]
}
