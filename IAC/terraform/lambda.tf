data "archive_file" "dispatcher" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/build/lambda_dispatcher.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project_name}-dispatcher"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "dispatcher" {
  function_name    = "${var.project_name}-dispatcher"
  role             = aws_iam_role.lambda_dispatcher.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.dispatcher.output_path
  source_code_hash = data.archive_file.dispatcher.output_base64sha256
  timeout          = var.lambda_timeout_seconds
  memory_size      = 256

  reserved_concurrent_executions = var.lambda_reserved_concurrency

  environment {
    variables = {
      ECS_CLUSTER          = aws_ecs_cluster.this.name
      ECS_TASK_DEFINITION  = aws_ecs_task_definition.transcoder.family
      CONTAINER_NAME       = var.container_name
      SUBNETS              = join(",", aws_subnet.public[*].id)
      SECURITY_GROUPS      = aws_security_group.egress_only.id
      ASSIGN_PUBLIC_IP     = var.assign_public_ip ? "ENABLED" : "DISABLED"
      PROCESSED_BUCKET     = var.processed_bucket_name
      COMPLETION_QUEUE_URL = aws_sqs_queue.completion.url
      REDIS_HOST           = local.redis_address
      REDIS_PORT           = tostring(local.redis_port)
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn                   = aws_sqs_queue.main.arn
  function_name                      = aws_lambda_function.dispatcher.arn
  batch_size                         = var.lambda_batch_size
  maximum_batching_window_in_seconds = var.lambda_batch_window_seconds
  function_response_types            = ["ReportBatchItemFailures"]
}
