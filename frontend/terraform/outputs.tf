output "frontend_url" {
  description = "The web app (HTTPS, AWS-issued certificate). The API is served on the same origin."
  value       = try("https://${aws_ecs_express_gateway_service.frontend.ingress_paths[0].endpoint}", null)
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
