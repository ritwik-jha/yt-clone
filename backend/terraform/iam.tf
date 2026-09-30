# Five roles, one job each:
#
#   api_execution / poller_execution   ECS agent: pull image, write logs
#                                      (+ the API's reads its Cognito secret)
#   api_task / poller_task             application code inside the container
#   express_infrastructure             ECS Express Mode: manages the API's ALB,
#                                      target group, SGs, cert, autoscaling
#
# Execution and task roles are split per service so the poller can never
# read the Cognito secret or call Cognito, and the API can never drain the
# completion queue or write terminal video status.

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

# ---------------------------------------------------------------- execution

data "aws_iam_policy_document" "execution_common" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPullBackendImage"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.backend.arn]
  }

  statement {
    sid       = "ContainerLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.backend.arn}:*"]
  }
}

data "aws_iam_policy_document" "api_execution" {
  source_policy_documents = [data.aws_iam_policy_document.execution_common.json]

  # Injects COGNITO_CLIENT_SECRET via the container `secrets` mechanism. The
  # parameter uses the AWS-managed aws/ssm key, which needs no kms:Decrypt
  # grant on the execution role.
  statement {
    sid       = "ReadCognitoClientSecret"
    effect    = "Allow"
    actions   = ["ssm:GetParameters"]
    resources = [local.pipeline.cognito_client_secret_parameter_arn]
  }
}

resource "aws_iam_role" "api_execution" {
  name               = "${var.backend_name}-api-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "api_execution" {
  name   = "${var.backend_name}-api-execution"
  role   = aws_iam_role.api_execution.id
  policy = data.aws_iam_policy_document.api_execution.json
}

resource "aws_iam_role" "poller_execution" {
  name               = "${var.backend_name}-poller-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "poller_execution" {
  name   = "${var.backend_name}-poller-execution"
  role   = aws_iam_role.poller_execution.id
  policy = data.aws_iam_policy_document.execution_common.json
}

# ---------------------------------------------------------------- API task

data "aws_iam_policy_document" "api_task" {
  statement {
    sid    = "CognitoAuthOperations"
    effect = "Allow"
    actions = [
      "cognito-idp:SignUp",
      "cognito-idp:ConfirmSignUp",
      "cognito-idp:InitiateAuth",
      "cognito-idp:GetUser",
    ]
    resources = [local.pipeline.cognito_user_pool_arn]
  }

  # PutItem for the initial PROCESSING row and the users mirror; no
  # UpdateItem — terminal status writes belong to the poller.
  statement {
    sid    = "VideoAndUserTables"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:Query",
    ]
    resources = [
      local.pipeline.dynamodb_table_arn,
      "${local.pipeline.dynamodb_table_arn}/index/*",
      local.pipeline.dynamodb_users_table_arn,
      "${local.pipeline.dynamodb_users_table_arn}/index/*",
    ]
  }

  # Grants the presigned PUT URLs their authority. The API process itself
  # never uploads an object.
  statement {
    sid     = "PresignedUploadAuthority"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "${local.pipeline.raw_bucket_arn}/videos/*",
      "${aws_s3_bucket.thumbnails.arn}/thumbnails/*",
    ]
  }
}

resource "aws_iam_role" "api_task" {
  name               = "${var.backend_name}-api-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "api_task" {
  name   = "${var.backend_name}-api-task"
  role   = aws_iam_role.api_task.id
  policy = data.aws_iam_policy_document.api_task.json
}

# ---------------------------------------------------------------- poller task

data "aws_iam_policy_document" "poller_task" {
  statement {
    sid    = "DrainCompletionQueue"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [local.pipeline.completion_queue_arn]
  }

  statement {
    sid       = "WriteTerminalVideoStatus"
    effect    = "Allow"
    actions   = ["dynamodb:UpdateItem"]
    resources = [local.pipeline.dynamodb_table_arn]
  }
}

resource "aws_iam_role" "poller_task" {
  name               = "${var.backend_name}-poller-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "poller_task" {
  name   = "${var.backend_name}-poller-task"
  role   = aws_iam_role.poller_task.id
  policy = data.aws_iam_policy_document.poller_task.json
}

# ------------------------------------------------ Express Mode infrastructure

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
  name               = "${var.backend_name}-express-infrastructure"
  assume_role_policy = data.aws_iam_policy_document.ecs_service_assume.json
}

resource "aws_iam_role_policy_attachment" "express_infrastructure" {
  role       = aws_iam_role.express_infrastructure.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSInfrastructureRoleforExpressGatewayServices"
}
