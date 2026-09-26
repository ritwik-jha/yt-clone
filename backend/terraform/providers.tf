terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = merge({
      Project   = var.project_name
      Component = var.backend_name
      ManagedBy = "terraform"
    }, var.tags)
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = var.aws_region

  # Every pipeline coordinate this stack needs comes from the pipeline state.
  # Nothing here re-declares a VPC, bucket, queue, table, or cache.
  pipeline = data.terraform_remote_state.pipeline.outputs

  backend_image = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com/${var.ecr_repository_name}:${var.image_tag}"
}

# The pipeline stack owns the region; a mismatch here would silently point the
# instance at cross-region queues and tables.
check "region_matches_pipeline" {
  assert {
    condition     = var.aws_region == local.pipeline.aws_region
    error_message = "aws_region (${var.aws_region}) does not match the pipeline stack region (${try(local.pipeline.aws_region, "unknown")})."
  }
}
