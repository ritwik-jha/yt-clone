# Instance SG. Lives in the pipeline's VPC so the instance can reach the
# ElastiCache cluster over private addressing.
resource "aws_security_group" "backend" {
  name        = "${var.backend_name}-sg"
  description = "Backend API + completion poller instance"
  vpc_id      = local.pipeline.vpc_id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.backend_name}-sg" }
}

# Both ingress rules are opt-in and default to absent: with no CIDRs set, the
# only way onto the box is SSM Session Manager, which needs no open port.
resource "aws_vpc_security_group_ingress_rule" "api" {
  count = length(var.api_ingress_cidrs)

  security_group_id = aws_security_group.backend.id
  description       = "API port"
  cidr_ipv4         = var.api_ingress_cidrs[count.index]
  from_port         = var.api_port
  to_port           = var.api_port
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  count = length(var.ssh_ingress_cidrs)

  security_group_id = aws_security_group.backend.id
  description       = "SSH"
  cidr_ipv4         = var.ssh_ingress_cidrs[count.index]
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

# The pipeline's redis SG only admits the Fargate/Lambda egress SG. Add the
# backend SG as a second source instead of editing the pipeline stack, so
# ownership of the rule follows ownership of the instance.
resource "aws_vpc_security_group_ingress_rule" "redis_from_backend" {
  security_group_id            = local.pipeline.redis_security_group_id
  description                  = "Redis TLS from the backend instance"
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}
