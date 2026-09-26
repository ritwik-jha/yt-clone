"""Lazy singletons for boto3 and Redis clients."""

from functools import lru_cache
import boto3
import redis

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
def ddb():
    return boto3.resource("dynamodb", region_name=get_settings().aws_region)


def users_table():
    return ddb().Table(get_settings().ddb_users_table)


def videos_table():
    return ddb().Table(get_settings().ddb_videos_table)


@lru_cache
def redis_client() -> redis.Redis:
    s = get_settings()
    return redis.Redis(
        host=s.redis_host,
        port=s.redis_port,
        ssl=s.redis_tls,
        ssl_cert_reqs=None,
        socket_timeout=5,
        socket_connect_timeout=5,
        decode_responses=True,
    )
