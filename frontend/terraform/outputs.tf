output "frontend_url" {
  description = "The web app, through the edge distribution. The API and the playback media (/media/) are served on the same origin."
  value       = "https://${aws_cloudfront_distribution.edge.domain_name}"
}

output "origin_url" {
  description = "The web app's Express Mode ALB, behind the edge distribution. Streams don't play here: /media/ exists only on frontend_url."
  value       = try("https://${local.frontend_origin_host}", null)
}

output "edge_distribution_id" {
  description = "For invalidations, e.g. after deleting a video whose segments are cached."
  value       = aws_cloudfront_distribution.edge.id
}

output "api_url" {
  description = "Where nginx forwards the API paths."
  value       = local.api_origin
}

output "ecr_repository_url" {
  value = aws_ecr_repository.frontend.repository_url
}

output "frontend_image" {
  value = local.frontend_image
}

output "service_name" {
  value = aws_ecs_express_gateway_service.frontend.service_name
}

output "ecs_cluster" {
  value = local.backend.ecs_cluster
}

output "log_group" {
  value = aws_cloudwatch_log_group.frontend.name
}

output "aws_region" {
  value = var.aws_region
}
