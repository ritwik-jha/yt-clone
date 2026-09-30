# PostgreSQL for the users and videos tables. Reachable only from the API and
# poller SGs (network.tf) and never given a public IP.
#
# RDS generates the master password and keeps it in Secrets Manager
# (manage_master_user_password), so it is never in this state or the task
# environment. The tasks get the secret ARN, read the password when they open
# a connection, and refetch it once if RDS has rotated it. The API applies
# pending Alembic migrations on start, before uvicorn serves.

# The pipeline VPC has only public subnets. With publicly_accessible = false
# the instance gets no public address, so a route to the internet gateway
# does not make it reachable from outside the VPC.
resource "aws_db_subnet_group" "main" {
  name        = var.backend_name
  description = "Backend PostgreSQL in the pipeline VPC"
  subnet_ids  = local.pipeline.public_subnet_ids
}

resource "aws_db_instance" "main" {
  identifier     = var.backend_name
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name                     = var.db_name
  username                    = var.db_username
  manage_master_user_password = true

  storage_type          = "gp3"
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  auto_minor_version_upgrade = true
  backup_retention_period    = var.db_backup_retention_days
  copy_tags_to_snapshot      = true

  # Destroying the stack needs db_deletion_protection = false applied first,
  # and leaves a final snapshot behind. Delete that snapshot before the next
  # destroy, or the fixed identifier collides.
  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.backend_name}-final"
}
