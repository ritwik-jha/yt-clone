# Identity provider for the backend. Cognito is the source of truth for
# credentials; the backend's PostgreSQL `users` table (backend/terraform) is
# a profile mirror keyed by cognito_sub, never a second copy of the password.
#
# username_attributes = ["email"] because backend/app/routers/auth.py signs
# up, confirms, and logs in with Username=<email> throughout — the pool must
# accept email as the username, not just as a standard attribute.

resource "aws_cognito_user_pool" "this" {
  name = var.cognito_user_pool_name

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # Cognito's built-in email sender delivers the numeric code that
  # POST /auth/verify-otp expects. No SES setup required.
  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
  }

  password_policy {
    minimum_length    = var.cognito_password_min_length
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }

  mfa_configuration = var.cognito_mfa_configuration

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # email is implied by username_attributes; name is required because
  # signup() always sends it and users.name in PostgreSQL is NOT NULL.
  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
  }

  schema {
    name                = "name"
    attribute_data_type = "String"
    required            = true
    mutable             = true
  }

  deletion_protection = var.cognito_deletion_protection
}

# Confidential client: generates a secret, so every SignUp/InitiateAuth call
# from the backend must carry SECRET_HASH (app/crypto.py::secret_hash).
resource "aws_cognito_user_pool_client" "backend" {
  name         = var.cognito_client_name
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = true

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  # Do not leak "user does not exist" vs "wrong password" on login.
  prevent_user_existence_errors = "ENABLED"

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30
}

# The backend's ECS task definitions inject the client secret from here
# (container `secrets`), so it never appears as a plain environment value in
# a task definition. The value already lives in this stack's state via the
# client resource above.
resource "aws_ssm_parameter" "cognito_client_secret" {
  name        = "/${var.project_name}/cognito/client-secret"
  description = "Cognito app client secret for the backend API"
  type        = "SecureString"
  value       = aws_cognito_user_pool_client.backend.client_secret
}
