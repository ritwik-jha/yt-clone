# Both containers ship stdout/stderr here through the Docker awslogs driver
# (streams "api" and "poller"), so nothing depends on reading journalctl on
# the box.
resource "aws_cloudwatch_log_group" "backend" {
  name              = "/${var.backend_name}"
  retention_in_days = var.log_retention_days
}
