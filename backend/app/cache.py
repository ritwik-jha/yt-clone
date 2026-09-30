"""Redis `video:meta:{video_id}` cache for GET /video/{video_id}.

Only videos anyone may watch (COMPLETED and not PRIVATE) are cached, so a hit
never needs an ownership check. The hash carries the spec's fields plus the
few the detail response needs beyond them (hls_url, visibility,
duration_seconds, created_at, creator_id, creator_created_at).

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
from app.schemas import CreatorDetail, VideoDetail

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
            thumbnail_url=data["thumbnail_url"],
            manifest_url=data["manifest_url"] or None,
            # .get: entries written before HLS output have no such field.
            hls_url=data.get("hls_url") or None,
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


def put_video(video: VideoDetail) -> None:
    mapping = {
        "id":                 str(video.id),
        "title":              video.title,
        "description":        video.description or "",
        "thumbnail_url":      video.thumbnail_url,
        "manifest_url":       video.manifest_url or "",
        "hls_url":            video.hls_url or "",
        "creator_name":       video.creator.name,
        "status":             video.status.value,
        "views_count":        str(video.views_count),
        "visibility":         video.visibility.value,
        "duration_seconds":   "" if video.duration_seconds is None else str(video.duration_seconds),
        "created_at":         video.created_at.isoformat(),
        "creator_id":         str(video.creator.id),
        "creator_created_at": video.creator.created_at.isoformat(),
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
