# Playback CDN for the processed (DASH) bucket. The bucket stays private;
# CloudFront reads it through Origin Access Control, so the only public path
# to a manifest or segment is https://<distribution>/<video_id>/dash/...
#
# DASH players resolve segment URLs relative to manifest.mpd, which is why
# this is a plain unsigned distribution rather than presigned S3 GETs: a
# presigned query string on the manifest does not carry to the segments.

resource "aws_cloudfront_origin_access_control" "processed" {
  name                              = "${var.project_name}-processed-oac"
  description                       = "CloudFront -> processed DASH bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

# Browser players (dash.js, Shaka) fetch cross-origin, so every response needs
# Access-Control-Allow-Origin. Added at the edge rather than via bucket CORS.
data "aws_cloudfront_response_headers_policy" "simple_cors" {
  name = "Managed-SimpleCORS"
}

resource "aws_cloudfront_distribution" "processed" {
  enabled         = true
  comment         = "${var.project_name} DASH playback"
  price_class     = var.cloudfront_price_class
  is_ipv6_enabled = true

  origin {
    origin_id                = "processed-s3"
    domain_name              = aws_s3_bucket.processed.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.processed.id
  }

  default_cache_behavior {
    target_origin_id           = "processed-s3"
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

data "aws_iam_policy_document" "processed_from_cloudfront" {
  statement {
    sid       = "AllowCloudFrontOAC"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.processed.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.processed.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "processed" {
  bucket = aws_s3_bucket.processed.id
  policy = data.aws_iam_policy_document.processed_from_cloudfront.json

  depends_on = [aws_s3_bucket_public_access_block.processed]
}
