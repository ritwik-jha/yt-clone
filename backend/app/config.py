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

    # PostgreSQL. On ECS the password is never in the environment: the app
    # reads it from the RDS-managed secret named by DB_SECRET_ARN (see
    # app/db.py). DB_PASSWORD is for local runs against docker compose.
    db_host: str = ""
    db_port: int = 5432
    db_name: str = ""
    db_user: str = ""
    db_password: str = ""
    db_secret_arn: str = ""
    db_sslmode: str = "require"
    db_pool_size: int = 5
    db_max_overflow: int = 5

    # S3
    s3_raw_videos_bucket: str = ""
    s3_thumbnails_bucket: str = ""
    # The pipeline's transcoder output bucket. Only DELETE /video/{id} uses it,
    # to remove a deleted video's DASH/HLS files.
    s3_processed_bucket: str = ""
    presigned_url_ttl_seconds: int = 3600

    # SQS completion queue (drained by poller worker)
    completion_queue_url: str = ""
    completion_poll_wait_seconds: int = 10
    completion_max_messages: int = 10

    # Redis. Progress keys are written by the transcoder and only read here;
    # the video:meta cache is owned by the API.
    redis_host: str = ""
    redis_port: int = 6379
    redis_tls: bool = True
    redis_progress_prefix: str = "video:progress"
    redis_meta_prefix: str = "video:meta"
    video_meta_cache_ttl_seconds: int = 3600

    # CloudFront domains the API builds playback and thumbnail URLs from.
    cloudfront_domain: str = ""
    thumbnails_cdn_domain: str = ""

    def require(self, *names: str) -> None:
        missing = [n.upper() for n in names if not getattr(self, n)]
        if missing:
            raise RuntimeError(f"missing required settings: {', '.join(missing)}")

    def require_database(self) -> None:
        self.require("db_host", "db_name", "db_user")
        if not (self.db_password or self.db_secret_arn):
            raise RuntimeError("missing required settings: DB_PASSWORD or DB_SECRET_ARN")

    @property
    def cors_origin_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
