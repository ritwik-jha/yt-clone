variable "aws_region" {
  description = "Region to deploy into. MUST match the pipeline and backend stacks."
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Shared project prefix, for tags."
  type        = string
  default     = "video-transcoder"
}

variable "frontend_name" {
  description = "Name prefix for every resource in this stack (and the ECS service)."
  type        = string
  default     = "video-frontend"
}

variable "pipeline_state_local_path" {
  description = "Path to the pipeline stack's terraform.tfstate."
  type        = string
  default     = "../../IAC/terraform/terraform.tfstate"
}

variable "backend_state_local_path" {
  description = "Path to the backend stack's terraform.tfstate."
  type        = string
  default     = "../../backend/terraform/terraform.tfstate"
}

variable "ecr_repository_name" {
  description = "ECR repository for the web app image."
  type        = string
  default     = "video-frontend"
}

variable "image_tag" {
  description = "Tag the service runs. Push a new tag and change this to deploy."
  type        = string
  default     = "latest"
}

variable "container_port" {
  description = "Port nginx listens on (deploy/nginx.conf.template)."
  type        = number
  default     = 8080
}

variable "cpu" {
  description = "Task CPU units."
  type        = string
  default     = "256"
}

variable "memory" {
  description = "Task memory in MiB."
  type        = string
  default     = "512"
}

variable "min_tasks" {
  description = "Autoscaling floor."
  type        = number
  default     = 1
}

variable "max_tasks" {
  description = "Autoscaling ceiling."
  type        = number
  default     = 2
}

variable "cloudfront_price_class" {
  description = "CloudFront price class for the edge distribution (web app and playback media). PriceClass_200 includes India edge locations."
  type        = string
  default     = "PriceClass_200"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.cloudfront_price_class)
    error_message = "cloudfront_price_class must be PriceClass_100, PriceClass_200, or PriceClass_All."
  }
}

variable "log_retention_days" {
  description = "CloudWatch retention for the nginx logs."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Extra tags merged into provider default_tags."
  type        = map(string)
  default     = {}
}
