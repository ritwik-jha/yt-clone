# Same pattern as the backend API (backend/terraform/network.tf): Express
# Mode's infrastructure role can't add rules to an SG it didn't create, so
# this SG admits the container port from the VPC CIDR, where the ALB lives.
# Internet traffic to the tasks' public IPs never carries a VPC source
# address, so it stays blocked.
resource "aws_security_group" "frontend" {
  name        = "${var.frontend_name}-sg"
  description = "Web app (nginx) tasks"
  vpc_id      = local.pipeline.vpc_id

  egress {
    description = "All outbound (ECR pulls, the public API endpoint)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.frontend_name}-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "frontend_from_vpc" {
  security_group_id = aws_security_group.frontend.id
  description       = "nginx port from the Express Mode ALB"
  cidr_ipv4         = local.pipeline.vpc_cidr
  from_port         = var.container_port
  to_port           = var.container_port
  ip_protocol       = "tcp"
}
