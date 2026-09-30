variable "aws_region" {
  description = "Region to deploy into. MUST match the pipeline stack's aws_region."
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Shared project prefix. Match the pipeline stack so tags line up."
  type        = string
  default     = "video-transcoder"
}

variable "backend_name" {
  description = "Name prefix for every resource in this stack (also the ECS cluster name)."
  type        = string
  default     = "video-backend"
}

# --- Pipeline state -------------------------------------------------------

variable "pipeline_state_backend" {
  description = "Backend type holding the pipeline stack's state (local or s3)."
  type        = string
  default     = "local"

  validation {
    condition     = contains(["local", "s3"], var.pipeline_state_backend)
    error_message = "pipeline_state_backend must be 'local' or 's3'."
  }
}

variable "pipeline_state_local_path" {
  description = "Path to the pipeline stack's terraform.tfstate when using the local backend."
  type        = string
  default     = "../../IAC/terraform/terraform.tfstate"
}

variable "pipeline_state_s3_bucket" {
  description = "S3 bucket holding the pipeline stack's state. Required when pipeline_state_backend = s3."
  type        = string
  default     = ""
}

variable "pipeline_state_s3_key" {
  description = "S3 key of the pipeline stack's state file."
  type        = string
  default     = "video-transcoder/terraform.tfstate"
}

# --- Thumbnails bucket ----------------------------------------------------

variable "thumbnails_bucket_name" {
  description = "Globally unique S3 bucket for thumbnail uploads. Owned by the backend, not the pipeline."
  type        = string
}

variable "thumbnails_cors_origins" {
  description = "Origins allowed to PUT thumbnails directly via presigned URL."
  type        = list(string)
  default     = ["*"]
}

# --- Container image ------------------------------------------------------

variable "ecr_repository_name" {
  description = "ECR repository for the backend image (separate from the transcoder's)."
  type        = string
  default     = "video-backend"
}

variable "image_tag" {
  description = "Tag both services run. Push a new tag and change this to deploy."
  type        = string
  default     = "latest"
}

# --- API service (ECS Express Mode) --------------------------------------

variable "api_port" {
  description = "Container port uvicorn listens on; Express Mode points the ALB target group here."
  type        = number
  default     = 8000
}

variable "api_cpu" {
  description = "API task CPU units (power of 2, 256-4096)."
  type        = string
  default     = "512"
}

variable "api_memory" {
  description = "API task memory in MiB (512-8192, must pair with api_cpu)."
  type        = string
  default     = "1024"
}

variable "api_min_tasks" {
  description = "Autoscaling floor for the API service."
  type        = number
  default     = 1
}

variable "api_max_tasks" {
  description = "Autoscaling ceiling for the API service."
  type        = number
  default     = 4
}

variable "api_cpu_target_percent" {
  description = "Average CPU the API autoscaler tracks."
  type        = number
  default     = 60
}

# --- Poller service -------------------------------------------------------

variable "poller_cpu" {
  description = "Poller task CPU units."
  type        = string
  default     = "256"
}

variable "poller_memory" {
  description = "Poller task memory in MiB."
  type        = string
  default     = "512"
}

variable "poller_desired_count" {
  description = "Poller replicas. One is enough; SQS redelivers on failure."
  type        = number
  default     = 1
}

# --- Application settings (become task environment) ----------------------

variable "cors_origins" {
  description = "Browser origins allowed to call the API with credentials. Empty allows any origin."
  type        = list(string)
  default     = []
}

variable "cookie_secure" {
  description = "Mark auth cookies Secure. Keep true: the Express Mode endpoint is HTTPS."
  type        = bool
  default     = true
}

variable "cookie_samesite" {
  description = "SameSite attribute for auth cookies (lax, strict, none)."
  type        = string
  default     = "lax"

  validation {
    condition     = contains(["lax", "strict", "none"], var.cookie_samesite)
    error_message = "cookie_samesite must be lax, strict, or none."
  }
}

variable "access_cookie_max_age" {
  description = "access_token cookie lifetime in seconds."
  type        = number
  default     = 3600
}

variable "refresh_cookie_max_age" {
  description = "refresh_token cookie lifetime in seconds."
  type        = number
  default     = 432000
}

variable "presigned_url_ttl_seconds" {
  description = "Lifetime of presigned upload URLs."
  type        = number
  default     = 3600
}

variable "completion_poll_wait_seconds" {
  description = "SQS long-poll wait for the poller."
  type        = number
  default     = 10
}

variable "completion_max_messages" {
  description = "Max messages per poller receive."
  type        = number
  default     = 10
}

# --- Logging --------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch retention for the api + poller log streams."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Extra tags merged into provider default_tags."
  type        = map(string)
  default     = {}
}
