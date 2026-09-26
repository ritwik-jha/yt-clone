output "aws_region" {
  value = var.aws_region
}

output "instance_id" {
  description = "Target for `aws ssm start-session`."
  value       = aws_instance.backend.id
}

output "public_ip" {
  value = var.associate_eip ? aws_eip.backend[0].public_ip : aws_instance.backend.public_ip
}

output "private_ip" {
  value = aws_instance.backend.private_ip
}

output "security_group_id" {
  description = "Attach this as the source on an ALB SG rule if you front the instance."
  value       = aws_security_group.backend.id
}

output "ecr_repository_url" {
  description = "Push the backend image here."
  value       = aws_ecr_repository.backend.repository_url
}

output "backend_image" {
  description = "Exact image reference the instance pulls."
  value       = local.backend_image
}

# Consumed by backend/scripts/generate-env.sh.
output "env_ssm_parameter" {
  value = aws_ssm_parameter.backend_env.name
}

output "thumbnails_bucket" {
  value = aws_s3_bucket.thumbnails.bucket
}

output "log_group" {
  value = aws_cloudwatch_log_group.backend.name
}
