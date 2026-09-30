"""Lazy singletons for boto3 and Redis clients."""

from functools import lru_cache
import boto3
import redis
from redis.backoff import NoBackoff
from redis.retry import Retry

from app.config import get_settings


@lru_cache
def cognito():
    return boto3.client("cognito-idp", region_name=get_settings().aws_region)


@lru_cache
def s3():
    return boto3.client("s3", region_name=get_settings().aws_region)


@lru_cache
def sqs():
    return boto3.client("sqs", region_name=get_settings().aws_region)


@lru_cache
def secretsmanager():
    return boto3.client("secretsmanager", region_name=get_settings().aws_region)


@lru_cache
def redis_client() -> redis.Redis:
    # Redis is a cache on the request path and every caller falls back when
    # it errors, so fail fast: short timeouts and no retries (redis-py
    # otherwise retries three times with backoff before raising).
    s = get_settings()
    return redis.Redis(
        host=s.redis_host,
        port=s.redis_port,
        ssl=s.redis_tls,
        ssl_cert_reqs=None,
        socket_timeout=1,
        socket_connect_timeout=1,
        retry=Retry(NoBackoff(), 0),
        decode_responses=True,
    )
