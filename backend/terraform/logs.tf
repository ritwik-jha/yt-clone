# Both services log here through the awslogs driver, under the stream
# prefixes "api" and "poller".
resource "aws_cloudwatch_log_group" "backend" {
  name              = "/${var.backend_name}"
  retention_in_days = var.log_retention_days
}
