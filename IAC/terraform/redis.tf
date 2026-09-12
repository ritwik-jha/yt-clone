resource "aws_elasticache_serverless_cache" "progress" {
  engine = "redis"
  name   = var.redis_cache_name

  cache_usage_limits {
    data_storage {
      maximum = 5
      unit    = "GB"
    }
    ecpu_per_second {
      maximum = 5000
    }
  }

  daily_snapshot_time      = "04:00"
  description              = "Video transcoder locks + progress"
  major_engine_version     = "7"
  security_group_ids       = [aws_security_group.redis.id]
  subnet_ids               = aws_subnet.public[*].id
  snapshot_retention_limit = 1
}

locals {
  # aws_elasticache_serverless_cache exposes endpoint as a list of {address, port}
  redis_address = aws_elasticache_serverless_cache.progress.endpoint[0].address
  redis_port    = aws_elasticache_serverless_cache.progress.endpoint[0].port
  redis_uri     = "${local.redis_address}:${local.redis_port}"
}
