# The instance pulls its whole .env from this parameter at boot and on every
# `systemctl restart video-backend`.
#
# Terraform only creates the parameter; it never holds the value. The real
# contents (including COGNITO_CLIENT_SECRET) are written by
# `backend/scripts/generate-env.sh --push-ssm`, and ignore_changes keeps a
# later `terraform apply` from clobbering them back to the placeholder.
resource "aws_ssm_parameter" "backend_env" {
  name        = "/${var.backend_name}/env"
  description = "dotenv contents for the backend API and completion poller"
  type        = "SecureString"
  value       = "PLACEHOLDER — run backend/scripts/generate-env.sh --push-ssm"

  lifecycle {
    ignore_changes = [value]
  }
}
