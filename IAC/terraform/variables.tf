variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Prefix used for naming resources"
  type        = string
  default     = "video-transcoder"
}

# ---------- Networking (VPC created by this module) ----------
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.42.0.0/16"
}

variable "az_count" {
  description = "Number of AZs / public subnets to create"
  type        = number
  default     = 2
}

variable "public_subnet_bits" {
  description = "Newbits added to vpc_cidr for each public subnet"
  type        = number
  default     = 8
}

variable "assign_public_ip" {
  description = "Assign public IP to Fargate tasks (true because we use public subnets)"
  type        = bool
  default     = true
}

# ---------- Storage ----------
variable "raw_bucket_name" {
  description = "S3 bucket for raw uploads (globally unique)"
  type        = string
}

variable "processed_bucket_name" {
  description = "S3 bucket for processed DASH/HLS output (globally unique)"
  type        = string
}

variable "cloudfront_price_class" {
  description = "CloudFront price class for the playback distribution. PriceClass_200 includes India edge locations."
  type        = string
  default     = "PriceClass_200"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.cloudfront_price_class)
    error_message = "cloudfront_price_class must be PriceClass_100, PriceClass_200, or PriceClass_All."
  }
}

# ---------- SQS ----------
variable "sqs_queue_name" {
  description = "Main SQS queue for S3 object-created events"
  type        = string
  default     = "video-processing-queue"
}

variable "sqs_dlq_name" {
  description = "Dead-letter queue for the ingest queue"
  type        = string
  default     = "video-processing-dlq"
}

variable "completion_queue_name" {
  description = "SQS queue that transcoder pushes completion messages to (consumed by backend poller)"
  type        = string
  default     = "video-completion-queue"
}

variable "completion_dlq_name" {
  description = "DLQ for the completion queue"
  type        = string
  default     = "video-completion-dlq"
}

variable "sqs_visibility_timeout_seconds" {
  description = "Ingest queue visibility timeout (must be >= 6x lambda timeout)"
  type        = number
  default     = 180
}

variable "completion_visibility_timeout_seconds" {
  description = "Completion queue visibility timeout"
  type        = number
  default     = 60
}

variable "sqs_max_receive_count" {
  description = "Messages redriven to DLQ after this many failed receives"
  type        = number
  default     = 3
}

# ---------- ECS / Transcoder ----------
variable "ecs_cluster_name" {
  description = "ECS cluster hosting Fargate transcoder tasks"
  type        = string
  default     = "ran-transcoder-cluster"
}

variable "ecs_task_family" {
  description = "ECS task definition family"
  type        = string
  default     = "video-transcoder"
}

variable "container_name" {
  description = "Container name in task definition (must match dispatcher overrides)"
  type        = string
  default     = "video-transcoder"
}

variable "ecr_repository_name" {
  description = "ECR repository for the transcoder image"
  type        = string
  default     = "video-transcoder"
}

variable "image_tag" {
  description = "Docker image tag published to ECR"
  type        = string
  default     = "latest"
}

variable "cpu_architecture" {
  description = "CPU architecture for the container image (ARM64 or X86_64)"
  type        = string
  default     = "ARM64"
}

variable "task_cpu" {
  description = "Fargate task CPU units"
  type        = string
  default     = "1024"
}

variable "task_memory" {
  description = "Fargate task memory in MiB"
  type        = string
  default     = "2048"
}

# ---------- Redis (ElastiCache Serverless) ----------
variable "redis_cache_name" {
  description = "Name of the ElastiCache Serverless Redis cache"
  type        = string
  default     = "video-progress-cache"
}

variable "redis_lock_ttl_seconds" {
  description = "TTL of the per-video Redis lock key (extended on every progress update)"
  type        = number
  default     = 1800
}

variable "redis_lock_key_prefix" {
  description = "Prefix for the per-video lock key: <prefix>:<video_guid>"
  type        = string
  default     = "video:lock"
}

variable "redis_progress_key_prefix" {
  description = "Prefix for the per-video progress key: <prefix>:<video_guid> -> percent"
  type        = string
  default     = "video:progress"
}

# ---------- Cognito (identity provider) ----------
variable "cognito_user_pool_name" {
  description = "Name of the Cognito user pool backing the backend's auth routes"
  type        = string
  default     = "video-transcoder-users"
}

variable "cognito_client_name" {
  description = "Name of the confidential app client the backend authenticates through"
  type        = string
  default     = "video-backend-client"
}

variable "cognito_password_min_length" {
  description = "Minimum password length enforced by the user pool"
  type        = number
  default     = 8
}

variable "cognito_mfa_configuration" {
  description = "Pool MFA requirement: OFF, ON, or OPTIONAL"
  type        = string
  default     = "OFF"

  validation {
    condition     = contains(["OFF", "ON", "OPTIONAL"], var.cognito_mfa_configuration)
    error_message = "cognito_mfa_configuration must be OFF, ON, or OPTIONAL."
  }
}

variable "cognito_deletion_protection" {
  description = "Set to ACTIVE to block accidental pool deletion. INACTIVE lets 'terraform destroy' work in dev."
  type        = string
  default     = "INACTIVE"

  validation {
    condition     = contains(["ACTIVE", "INACTIVE"], var.cognito_deletion_protection)
    error_message = "cognito_deletion_protection must be ACTIVE or INACTIVE."
  }
}

# ---------- Lambda dispatcher ----------
variable "lambda_batch_size" {
  description = "Max SQS messages per Lambda invocation"
  type        = number
  default     = 10
}

variable "lambda_batch_window_seconds" {
  description = "Max seconds Lambda waits to batch messages"
  type        = number
  default     = 5
}

variable "lambda_reserved_concurrency" {
  description = "Reserved concurrency for dispatcher Lambda (-1 = unreserved)"
  type        = number
  default     = -1
}

variable "lambda_timeout_seconds" {
  description = "Dispatcher Lambda timeout"
  type        = number
  default     = 30
}

variable "log_retention_days" {
  description = "CloudWatch log retention"
  type        = number
  default     = 14
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}
