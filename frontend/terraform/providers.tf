terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # aws_ecs_express_gateway_service first shipped in the 6.x line.
      version = "~> 6.23"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = merge({
      Project   = var.project_name
      Component = var.frontend_name
      ManagedBy = "terraform"
    }, var.tags)
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  pipeline = data.terraform_remote_state.pipeline.outputs
  backend  = data.terraform_remote_state.backend.outputs

  # nginx forwards the API paths here (see ../deploy/nginx.conf.template).
  api_origin = trimsuffix(local.backend.api_url, "/")
  api_host   = trimprefix(local.api_origin, "https://")

  frontend_image = "${aws_ecr_repository.frontend.repository_url}:${var.image_tag}"
}

check "region_matches_pipeline" {
  assert {
    condition     = var.aws_region == local.pipeline.aws_region
    error_message = "aws_region (${var.aws_region}) does not match the pipeline stack region (${try(local.pipeline.aws_region, "unknown")})."
  }
}

check "backend_has_media_key_group" {
  assert {
    condition     = try(local.backend.media_key_group_id, "") != ""
    error_message = "The backend stack has no media_key_group_id output yet. Apply backend/terraform first (DEPLOY_AWS.md §4)."
  }
}

check "pipeline_has_processed_origin" {
  assert {
    condition     = try(local.pipeline.processed_bucket_regional_domain_name, "") != ""
    error_message = "The pipeline stack has no processed_bucket_regional_domain_name output yet. Re-apply IAC/terraform first."
  }
}

check "backend_has_api_url" {
  assert {
    condition     = startswith(try(local.backend.api_url, ""), "https://")
    error_message = "The backend stack has no https api_url output yet. Apply backend/terraform first."
  }
}
