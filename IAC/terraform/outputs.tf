output "aws_region" {
  value = var.aws_region
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC IPv4 CIDR. The backend API SG admits its container port from here (the Express Mode ALB)."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "workload_security_group_id" {
  value = aws_security_group.egress_only.id
}

output "redis_security_group_id" {
  value = aws_security_group.redis.id
}

output "raw_bucket" {
  value = aws_s3_bucket.raw.bucket
}

output "processed_bucket" {
  value = aws_s3_bucket.processed.bucket
}

output "ingest_queue_url" {
  value = aws_sqs_queue.main.url
}

output "ingest_dlq_url" {
  value = aws_sqs_queue.dlq.url
}

output "completion_queue_url" {
  value = aws_sqs_queue.completion.url
}

output "completion_queue_arn" {
  value = aws_sqs_queue.completion.arn
}

output "completion_dlq_url" {
  value = aws_sqs_queue.completion_dlq.url
}

output "redis_endpoint" {
  value = local.redis_uri
}

output "redis_host" {
  value = local.redis_address
}

# Backend reads progress under this prefix; transcoder writes it. Exported so
# the two cannot drift.
output "redis_progress_key_prefix" {
  value = var.redis_progress_key_prefix
}

output "redis_port" {
  value = local.redis_port
}

output "dynamodb_table" {
  value = aws_dynamodb_table.video_status.name
}

output "dynamodb_table_arn" {
  value = aws_dynamodb_table.video_status.arn
}

output "dynamodb_users_table" {
  value = aws_dynamodb_table.users.name
}

output "dynamodb_users_table_arn" {
  value = aws_dynamodb_table.users.arn
}

output "raw_bucket_arn" {
  value = aws_s3_bucket.raw.arn
}

output "processed_bucket_arn" {
  value = aws_s3_bucket.processed.arn
}

output "ecs_cluster" {
  value = aws_ecs_cluster.this.name
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.transcoder.arn
}

output "ecr_repository_url" {
  value = aws_ecr_repository.transcoder.repository_url
}

output "lambda_function_name" {
  value = aws_lambda_function.dispatcher.function_name
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "cognito_user_pool_arn" {
  value = aws_cognito_user_pool.this.arn
}

output "cognito_user_pool_client_id" {
  value = aws_cognito_user_pool_client.backend.id
}

output "cognito_user_pool_client_secret" {
  value     = aws_cognito_user_pool_client.backend.client_secret
  sensitive = true
}

output "cognito_client_secret_parameter_arn" {
  description = "SSM SecureString the backend API task reads COGNITO_CLIENT_SECRET from."
  value       = aws_ssm_parameter.cognito_client_secret.arn
}

output "cloudfront_domain_name" {
  description = "Playback domain for the processed bucket. manifest_url = https://<this>/<manifest_key>."
  value       = aws_cloudfront_distribution.processed.domain_name
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.processed.id
}
