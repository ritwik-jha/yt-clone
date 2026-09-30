# Read CDN for thumbnails. The bucket stays private; CloudFront reads it
# through Origin Access Control. The API returns
# https://<distribution>/<thumbnail_s3_key> as each video's thumbnail_url.
# Mirrors the pipeline's playback distribution (IAC/terraform/cloudfront.tf).

resource "aws_cloudfront_origin_access_control" "thumbnails" {
  name                              = "${var.backend_name}-thumbnails-oac"
  description                       = "CloudFront -> thumbnails bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

# Flutter web's CanvasKit renderer fetches images cross-origin, so responses
# need Access-Control-Allow-Origin.
data "aws_cloudfront_response_headers_policy" "simple_cors" {
  name = "Managed-SimpleCORS"
}

resource "aws_cloudfront_distribution" "thumbnails" {
  enabled         = true
  comment         = "${var.backend_name} thumbnails"
  price_class     = var.thumbnails_cdn_price_class
  is_ipv6_enabled = true

  origin {
    origin_id                = "thumbnails-s3"
    domain_name              = aws_s3_bucket.thumbnails.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.thumbnails.id
  }

  default_cache_behavior {
    target_origin_id           = "thumbnails-s3"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.simple_cors.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

data "aws_iam_policy_document" "thumbnails_from_cloudfront" {
  statement {
    sid       = "AllowCloudFrontOAC"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.thumbnails.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.thumbnails.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "thumbnails" {
  bucket = aws_s3_bucket.thumbnails.id
  policy = data.aws_iam_policy_document.thumbnails_from_cloudfront.json

  depends_on = [aws_s3_bucket_public_access_block.thumbnails]
}
