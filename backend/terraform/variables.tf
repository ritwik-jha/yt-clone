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
  description = "Name prefix for every resource in this stack."
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

# Cognito is provisioned by the pipeline stack (IAC/terraform/cognito.tf).
# This stack reads its pool ARN from local.pipeline — no variable needed.

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
  description = "Tag the instance pulls on deploy."
  type        = string
  default     = "latest"
}

# --- Instance -------------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type. Must match cpu_architecture (t4g.* = arm64, t3.* = x86_64)."
  type        = string
  default     = "t4g.small"
}

variable "cpu_architecture" {
  description = "Architecture for the AMI and the backend image build."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "amd64"], var.cpu_architecture)
    error_message = "cpu_architecture must be 'arm64' or 'amd64'."
  }
}

variable "ubuntu_version" {
  description = "Ubuntu LTS release for the instance AMI."
  type        = string
  default     = "24.04"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size. Images plus logs fit comfortably in 30 GB."
  type        = number
  default     = 30
}

variable "key_pair_name" {
  description = "Optional EC2 key pair for SSH. Leave null and use SSM Session Manager."
  type        = string
  default     = null
}

variable "associate_eip" {
  description = "Attach a stable Elastic IP so DNS does not change on instance replacement."
  type        = bool
  default     = true
}

# --- Ingress --------------------------------------------------------------

variable "api_ingress_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the API port directly. Empty (the default) means
    no inbound rule at all — reach the instance through SSM port forwarding,
    or put an ALB in front and open the port to the ALB's SG instead.
  EOT
  type        = list(string)
  default     = []
}

variable "api_port" {
  description = "Host port the API container publishes on."
  type        = number
  default     = 8000
}

variable "ssh_ingress_cidrs" {
  description = "CIDRs allowed to SSH. Prefer SSM Session Manager and leave this empty."
  type        = list(string)
  default     = []
}

# --- Logging --------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch retention for the api + poller container log streams."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Extra tags merged into provider default_tags."
  type        = map(string)
  default     = {}
}
