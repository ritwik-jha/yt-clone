"""Runtime configuration loaded from environment / .env file."""

from functools import lru_cache
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # Process-specific values default to "" and each entrypoint require()s its
    # own, so the poller runs without the Cognito secret.
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # App
    app_host: str = "0.0.0.0"
    app_port: int = 8000
    cors_origins: str = ""
    access_cookie_max_age: int = 3600
    refresh_cookie_max_age: int = 432000
    cookie_secure: bool = True
    cookie_samesite: str = "lax"

    # AWS
    aws_region: str = "ap-south-1"

    # Cognito
    cognito_user_pool_id: str = ""
    cognito_client_id: str = ""
    cognito_client_secret: str = ""

    # DynamoDB
    ddb_videos_table: str = "video-status"
    ddb_users_table: str = "users"

    # S3
    s3_raw_videos_bucket: str = ""
    s3_thumbnails_bucket: str = ""
    presigned_url_ttl_seconds: int = 3600

    # SQS completion queue (drained by poller worker)
    completion_queue_url: str = ""
    completion_poll_wait_seconds: int = 10
    completion_max_messages: int = 10

    # Redis (progress reads only — locks + writes belong to the transcoder)
    redis_host: str = ""
    redis_port: int = 6379
    redis_tls: bool = True
    redis_progress_prefix: str = "video:progress"

    # CloudFront domain in front of the processed bucket (poller builds
    # manifest_url from it)
    cloudfront_domain: str = ""

    def require(self, *names: str) -> None:
        missing = [n.upper() for n in names if not getattr(self, n)]
        if missing:
            raise RuntimeError(f"missing required settings: {', '.join(missing)}")

    @property
    def cors_origin_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
