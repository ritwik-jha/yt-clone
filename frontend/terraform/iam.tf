# Two roles: the execution role (pull the image, write logs) and the Express
# Mode infrastructure role (ALB, target group, cert, autoscaling). nginx calls
# no AWS APIs, so the task has no task role.

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPullFrontendImage"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.frontend.arn]
  }

  statement {
    sid       = "ContainerLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.frontend.arn}:*"]
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.frontend_name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "execution" {
  name   = "pull-and-log"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

data "aws_iam_policy_document" "ecs_service_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "express_infrastructure" {
  name               = "${var.frontend_name}-express-infrastructure"
  assume_role_policy = data.aws_iam_policy_document.ecs_service_assume.json
}

resource "aws_iam_role_policy_attachment" "express_infrastructure" {
  role       = aws_iam_role.express_infrastructure.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSInfrastructureRoleforExpressGatewayServices"
}
