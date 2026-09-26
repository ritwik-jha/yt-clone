resource "aws_iam_role" "instance" {
  name = "${var.backend_name}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.backend_name}-instance-profile"
  role = aws_iam_role.instance.name
}

# Session Manager shell access, so the stack needs no SSH key and no open
# port 22.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance" {
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

  statement {
    sid    = "VideoAndUserTables"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
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
    sid       = "ReadBackendEnv"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.backend_env.arn]
  }

  # SecureString decryption under the AWS-managed SSM key. Scoped by
  # ViaService so the role cannot decrypt anything outside Parameter Store.
  statement {
    sid       = "DecryptBackendEnv"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${local.region}.amazonaws.com"]
    }
  }

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
    sid    = "ContainerLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.backend.arn}:*"]
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "${var.backend_name}-instance-policy"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}
