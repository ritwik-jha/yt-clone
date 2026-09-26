locals {
  ecr_registry = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"

  # The compose file, deploy script, and unit are the same files the repo
  # ships, base64-embedded rather than re-written inline, so the instance can
  # never drift from what is under version control.
  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    aws_region    = var.aws_region
    env_param     = aws_ssm_parameter.backend_env.name
    backend_image = local.backend_image
    ecr_registry  = local.ecr_registry
    log_group     = aws_cloudwatch_log_group.backend.name

    compose_b64 = base64encode(file("${path.module}/../docker-compose.yml"))
    deploy_b64  = base64encode(file("${path.module}/../scripts/deploy.sh"))
    unit_b64    = base64encode(file("${path.module}/../systemd/video-backend.service"))
  })
}

resource "aws_instance" "backend" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type
  subnet_id              = local.pipeline.public_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.backend.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  key_name               = var.key_pair_name

  user_data                   = local.user_data
  user_data_replace_on_change = true

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    encrypted   = true
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2 # containers reach IMDS for credentials
  }

  tags = { Name = var.backend_name }

  lifecycle {
    precondition {
      condition = (
        (var.cpu_architecture == "arm64" && can(regex("^(t4g|m6g|m7g|c6g|c7g|r6g|r7g)\\.", var.instance_type))) ||
        (var.cpu_architecture == "amd64" && !can(regex("^(t4g|m6g|m7g|c6g|c7g|r6g|r7g)\\.", var.instance_type)))
      )
      error_message = "instance_type ${var.instance_type} does not match cpu_architecture ${var.cpu_architecture}; a mismatched AMI will not boot."
    }
  }
}

# Without this the public address changes on every instance replacement, and
# whatever DNS record or ALB target points at it has to be re-pointed.
resource "aws_eip" "backend" {
  count    = var.associate_eip ? 1 : 0
  instance = aws_instance.backend.id
  domain   = "vpc"
  tags     = { Name = "${var.backend_name}-eip" }
}
