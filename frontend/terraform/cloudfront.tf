# The edge: one CloudFront distribution in front of the web app and the
# playback media, so the browser sees a single origin.
#
#   /*         -> the web app's Express Mode ALB (nginx, which forwards the
#                 API paths to the API). Not cached; every viewer header,
#                 cookie and query string is passed on except Host, which
#                 must stay the ALB's own for Express Mode's routing.
#   /media/*   -> the processed bucket through OAC, cached at the edge, and
#                 only for requests carrying CloudFront signed cookies made
#                 with the backend's key group. POST /video/{id}/playback
#                 sets them, scoped to one video's folder. The viewer-request
#                 function strips /media and refuses query strings and odd
#                 paths (media-viewer-request.js).
#
# Same origin means the signed cookies, like the auth cookies, are
# first-party and sent by the players without CORS or credentials settings.
#
# This stack owns the processed bucket's policy: the distribution that may
# read it is created here, after the pipeline stack.

locals {
  frontend_origin_host = try(aws_ecs_express_gateway_service.frontend.ingress_paths[0].endpoint, null)
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_origin_access_control" "media" {
  name                              = "${var.frontend_name}-media-oac"
  description                       = "Edge distribution -> processed (HLS/DASH) bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_function" "media_viewer_request" {
  name    = "${var.frontend_name}-media-viewer-request"
  runtime = "cloudfront-js-2.0"
  comment = "Strip /media; refuse query strings and odd paths"
  publish = true
  code    = file("${path.module}/media-viewer-request.js")
}

resource "aws_cloudfront_distribution" "edge" {
  enabled         = true
  comment         = "${var.frontend_name} web app and playback media"
  price_class     = var.cloudfront_price_class
  is_ipv6_enabled = true
  http_version    = "http2and3"

  origin {
    origin_id   = "web-app"
    domain_name = local.frontend_origin_host

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      origin_read_timeout    = 60
    }
  }

  origin {
    origin_id                = "media-s3"
    domain_name              = local.pipeline.processed_bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.media.id
  }

  default_cache_behavior {
    target_origin_id         = "web-app"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
  }

  ordered_cache_behavior {
    path_pattern           = "/media/*"
    target_origin_id       = "media-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    # The cache key leaves the cookies out: CloudFront checks the signature
    # on every request, cached or not, and the bytes are the same for all.
    cache_policy_id    = data.aws_cloudfront_cache_policy.caching_optimized.id
    trusted_key_groups = [local.backend.media_key_group_id]

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.media_viewer_request.arn
    }
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

data "aws_iam_policy_document" "processed_from_edge" {
  statement {
    sid       = "AllowEdgeDistributionOAC"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${local.pipeline.processed_bucket_arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.edge.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "processed" {
  bucket = local.pipeline.processed_bucket
  policy = data.aws_iam_policy_document.processed_from_edge.json
}
