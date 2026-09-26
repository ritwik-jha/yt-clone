# Thumbnails bucket. Clients PUT here directly with a presigned URL minted by
# GET /upload/video/url/thumbnail. The pipeline never touches it, which is why
# it lives in the backend stack rather than IAC/terraform.
resource "aws_s3_bucket" "thumbnails" {
  bucket        = var.thumbnails_bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "thumbnails" {
  bucket                  = aws_s3_bucket.thumbnails.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "thumbnails" {
  bucket = aws_s3_bucket.thumbnails.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Browser clients PUT cross-origin against the presigned URL, so the preflight
# has to succeed on the bucket itself.
resource "aws_s3_bucket_cors_configuration" "thumbnails" {
  bucket = aws_s3_bucket.thumbnails.id

  cors_rule {
    allowed_methods = ["PUT", "GET", "HEAD"]
    allowed_origins = var.thumbnails_cors_origins
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}
