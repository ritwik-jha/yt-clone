"""Redis `video:meta:{video_id}` cache for GET /video/{video_id}.

Only videos anyone may watch (COMPLETED and not PRIVATE) are cached, so a hit
never needs an ownership check. The hash carries the spec's fields plus the
few the detail response needs beyond them (visibility, duration_seconds,
created_at, creator_id, creator_created_at). It holds the S3 keys rather than
URLs, and the URLs are built on read (app/video_views.py), so a change to
MEDIA_BASE_URL or THUMBNAILS_CDN_DOMAIN applies to cached videos at once.
Entries written in the older URL form miss and are rewritten.

PATCH and DELETE /video/{video_id} drop the key after they commit. Any other
path that changes a cached field must do the same.

Redis is an optimisation here: every failure is logged and the caller falls
back to PostgreSQL.
"""

import logging
from typing import Optional
from uuid import UUID

import redis
from pydantic import ValidationError

from app.clients import redis_client
from app.config import get_settings
from app.models import Video
from app.schemas import CreatorDetail, VideoDetail
from app.video_views import manifest_url, thumbnail_url

log = logging.getLogger(__name__)


def _key(video_id: UUID) -> str:
    return f"{get_settings().redis_meta_prefix}:{video_id}"


def get_video(video_id: UUID) -> Optional[VideoDetail]:
    key = _key(video_id)
    try:
        data = redis_client().hgetall(key)
    except redis.RedisError as exc:
        log.warning("video meta cache read failed: %s", exc)
        return None
    if not data:
        return None
    try:
        return VideoDetail(
            id=data["id"],
            title=data["title"],
            description=data["description"] or None,
            thumbnail_url=thumbnail_url(data["thumbnail_key"]),
            manifest_url=manifest_url(data["manifest_key"]),
            hls_url=manifest_url(data["hls_key"]),
            views_count=int(data["views_count"]),
            duration_seconds=int(data["duration_seconds"]) if data["duration_seconds"] else None,
            created_at=data["created_at"],
            visibility=data["visibility"],
            status=data["status"],
            creator=CreatorDetail(
                id=data["creator_id"],
                name=data["creator_name"],
                created_at=data["creator_created_at"],
            ),
        )
    except (KeyError, ValueError, ValidationError):
        log.warning("ignoring malformed cache entry %s", key)
        return None


def put_video(video: Video) -> None:
    """Needs `video.user` loaded."""
    mapping = {
        "id":                 str(video.id),
        "title":              video.title,
        "description":        video.description or "",
        "thumbnail_key":      video.thumbnail_s3_key,
        "manifest_key":       video.dash_manifest_s3_key or "",
        "hls_key":            video.hls_manifest_s3_key or "",
        "creator_name":       video.user.name,
        "status":             video.status.value,
        "views_count":        str(video.views_count),
        "visibility":         video.visibility.value,
        "duration_seconds":   "" if video.duration_seconds is None else str(video.duration_seconds),
        "created_at":         video.created_at.isoformat(),
        "creator_id":         str(video.user.id),
        "creator_created_at": video.user.created_at.isoformat(),
    }
    key = _key(video.id)
    try:
        pipe = redis_client().pipeline()
        pipe.hset(key, mapping=mapping)
        pipe.expire(key, get_settings().video_meta_cache_ttl_seconds)
        pipe.execute()
    except redis.RedisError as exc:
        log.warning("video meta cache write failed: %s", exc)


def drop_video(video_id: UUID) -> None:
    """Forget a cached video. With Redis down the stale entry, if any, lives
    until its TTL."""
    try:
        redis_client().delete(_key(video_id))
    except redis.RedisError as exc:
        log.warning("video meta cache delete failed: %s", exc)
