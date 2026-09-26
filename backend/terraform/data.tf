# The pipeline stack (IAC/terraform) is applied first; this stack consumes its
# outputs rather than re-declaring or importing any of its resources.
data "terraform_remote_state" "pipeline" {
  backend = var.pipeline_state_backend

  config = var.pipeline_state_backend == "s3" ? {
    bucket = var.pipeline_state_s3_bucket
    key    = var.pipeline_state_s3_key
    region = var.aws_region
    } : {
    path = var.pipeline_state_local_path
  }
}

# Canonical publishes the current Ubuntu AMI id as a public SSM parameter, so
# the instance always launches on a patched image without an ami filter block
# that drifts.
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/${var.ubuntu_version}/stable/current/${var.cpu_architecture}/hvm/ebs-gp3/ami-id"
}
