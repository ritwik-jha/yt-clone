# Both services run in the pipeline VPC's public subnets (the VPC has no NAT),
# so tasks get public IPs for ECR/AWS API egress.
#
# The API SG is passed to Express Mode, which creates the ALB and its SG. The
# API SG is also the source on the Redis rule below. The poller SG opens no
# ingress.
resource "aws_security_group" "api" {
  name        = "${var.backend_name}-api-sg"
  description = "Backend API tasks"
  vpc_id      = local.pipeline.vpc_id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.backend_name}-api-sg" }
}

# The Express Mode infrastructure role can only add rules to SGs tagged
# AmazonECSManaged=true, so it cannot open this SG to its ALB, and AWS does
# not document whether it still attaches its own service SG when one is
# supplied. Admitting the container port from the VPC CIDR lets the ALB
# (which sits in this VPC) reach the tasks either way. Internet traffic to the
# tasks' public IPs never carries a VPC source address, so it stays blocked.
resource "aws_vpc_security_group_ingress_rule" "api_from_vpc" {
  security_group_id = aws_security_group.api.id
  description       = "API container port from the Express Mode ALB"
  cidr_ipv4         = local.pipeline.vpc_cidr
  from_port         = var.api_port
  to_port           = var.api_port
  ip_protocol       = "tcp"
}

resource "aws_security_group" "poller" {
  name        = "${var.backend_name}-poller-sg"
  description = "Completion poller tasks, egress only"
  vpc_id      = local.pipeline.vpc_id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.backend_name}-poller-sg" }
}

# Only the API reads progress from Redis; the poller never touches it. Added
# here rather than in the pipeline stack so ownership follows the consumer.
resource "aws_vpc_security_group_ingress_rule" "redis_from_api" {
  security_group_id            = local.pipeline.redis_security_group_id
  description                  = "Redis TLS from the backend API tasks"
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}
