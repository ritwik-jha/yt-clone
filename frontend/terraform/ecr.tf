resource "aws_ecr_repository" "frontend" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"
  # Static files only; let destroy remove the images too.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "frontend" {
  repository = aws_ecr_repository.frontend.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_cloudwatch_log_group" "frontend" {
  name              = "/${var.frontend_name}"
  retention_in_days = var.log_retention_days
}
