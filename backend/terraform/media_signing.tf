# Signing key for the playback cookies (app/media_signing.py).
#
# The edge distribution (frontend/terraform/cloudfront.tf) only serves
# /media/* to requests carrying CloudFront signed cookies made with a key in
# this key group. The API signs them in POST /video/{id}/playback.
#
# Like every secret here, the private key never passes through Terraform:
# DEPLOY_AWS.md §4 generates the pair once and stores it as two SSM
# parameters under var.media_signing_parameter_prefix,
#
#   <prefix>/private   SecureString, PEM private key
#   <prefix>/public    String, PEM public key
#
# This stack reads only the public one. The API's execution role injects the
# private one as MEDIA_PRIVATE_KEY (ecs.tf), referenced by ARN.
#
# Rotation: store a second pair, add a second aws_cloudfront_public_key to the
# key group, point MEDIA_KEY_PAIR_ID and the secret at it, wait
# MEDIA_COOKIE_TTL_SECONDS, then remove the old key.

data "aws_ssm_parameter" "media_public_key" {
  name = "${var.media_signing_parameter_prefix}/public"
}

locals {
  media_private_key_parameter_arn = "arn:aws:ssm:${local.region}:${local.account_id}:parameter${var.media_signing_parameter_prefix}/private"
}

resource "aws_cloudfront_public_key" "media" {
  # A prefix, not a name: a changed key is a new key (new id, which the key
  # group and MEDIA_KEY_PAIR_ID pick up in the same apply), created before
  # the old one is deleted because the key group still holds the old one.
  name_prefix = "${var.backend_name}-media-"
  comment     = "Verifies the API's playback cookies"
  # One trailing newline, as in a PEM file: the shell strips it on the way
  # into SSM, and without it the key would differ from CloudFront's copy.
  encoded_key = "${trimspace(data.aws_ssm_parameter.media_public_key.value)}\n"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudfront_key_group" "media" {
  name    = "${var.backend_name}-media"
  comment = "Signers the edge distribution trusts for /media/*"
  items   = [aws_cloudfront_public_key.media.id]
}
