output "aws_region" {
  value = var.aws_region
}

output "api_url" {
  description = "HTTPS endpoint Express Mode assigned to the API (ALB, AWS-issued certificate)."
  value       = try("https://${aws_ecs_express_gateway_service.api.ingress_paths[0].endpoint}", null)
}

output "ecs_cluster" {
  value = aws_ecs_cluster.backend.name
}

output "api_service_name" {
  value = aws_ecs_express_gateway_service.api.service_name
}

output "api_service_arn" {
  value = aws_ecs_express_gateway_service.api.service_arn
}

output "poller_service_name" {
  value = aws_ecs_service.poller.name
}

output "api_security_group_id" {
  description = "Extra SG on the API tasks; the Redis ingress rule references it."
  value       = aws_security_group.api.id
}

output "ecr_repository_url" {
  description = "Push the backend image here."
  value       = aws_ecr_repository.backend.repository_url
}

output "backend_image" {
  description = "Exact image reference both services run."
  value       = local.backend_image
}

output "thumbnails_bucket" {
  value = aws_s3_bucket.thumbnails.bucket
}

output "thumbnails_cdn_domain" {
  description = "CloudFront domain serving thumbnails; the API builds thumbnail_url from it."
  value       = aws_cloudfront_distribution.thumbnails.domain_name
}

output "db_endpoint" {
  description = "RDS PostgreSQL host:port. Reachable only from the API and poller tasks."
  value       = aws_db_instance.main.endpoint
}

output "db_secret_arn" {
  description = "Secrets Manager secret holding the RDS-managed master credentials (not the value)."
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}

output "log_group" {
  value = aws_cloudwatch_log_group.backend.name
}
