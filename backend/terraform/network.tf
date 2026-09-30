# Both services run in the pipeline VPC's public subnets (the VPC has no NAT),
# so tasks get public IPs for ECR/AWS API egress.
#
# The API SG is passed to Express Mode, which creates the ALB and its SG. The
# API SG is also the source on the Redis rule below, and the API and poller
# SGs are the only sources the database SG admits. The poller SG opens no
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

# Only the API uses Redis (progress reads and the video metadata cache); the
# poller never touches it. Added here rather than in the pipeline stack so
# ownership follows the consumer.
resource "aws_vpc_security_group_ingress_rule" "redis_from_api" {
  security_group_id            = local.pipeline.redis_security_group_id
  description                  = "Redis TLS from the backend API tasks"
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

# No egress rules: RDS never initiates connections, and Terraform drops the
# default allow-all egress rule on SGs it creates.
resource "aws_security_group" "db" {
  name        = "${var.backend_name}-db-sg"
  description = "Backend PostgreSQL, API and poller tasks only"
  vpc_id      = local.pipeline.vpc_id

  tags = { Name = "${var.backend_name}-db-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_api" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the backend API tasks"
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_poller" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the completion poller tasks"
  referenced_security_group_id = aws_security_group.poller.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
