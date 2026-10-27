"""How a video row is shown to API callers, shared by the routers.

Playback and thumbnail URLs are derived from the stored S3 keys at read time
(see routers/video.py), and `viewable_by` is the SQL form of the rule that
decides who may watch a video.
"""

from uuid import UUID

from sqlalchemy import ColumnElement, and_, or_

from app.config import get_settings
from app.models import Video, VideoStatus, Visibility
from app.schemas import Creator, FeedItem


def thumbnail_url(key: str) -> str:
    return f"https://{get_settings().thumbnails_cdn_domain}/{key}"


def manifest_url(key: str | None) -> str | None:
    """MEDIA_BASE_URL + key: by default `/media/<key>`, relative to the API's
    origin, where the edge distribution serves it to holders of the signed
    cookies from POST /video/{id}/playback."""
    if not key:
        return None
    return f"{get_settings().media_base_url.rstrip('/')}/{key.lstrip('/')}"


def feed_fields(video: Video) -> dict:
    return {
        "id":               video.id,
        "title":            video.title,
        "description":      video.description,
        "thumbnail_url":    thumbnail_url(video.thumbnail_s3_key),
        "manifest_url":     manifest_url(video.dash_manifest_s3_key),
        "hls_url":          manifest_url(video.hls_manifest_s3_key),
        "views_count":      video.views_count,
        "duration_seconds": video.duration_seconds,
        "created_at":       video.created_at,
    }


def to_feed_item(video: Video) -> FeedItem:
    """Needs `video.user` loaded (joinedload(Video.user))."""
    return FeedItem(
        **feed_fields(video),
        creator=Creator(id=video.user.id, name=video.user.name),
    )


def viewable_by(user_id: UUID) -> ColumnElement[bool]:
    """Videos `user_id` may watch: COMPLETED, and not PRIVATE unless theirs.
    The SQL twin of the check GET /video/{id} makes on one row."""
    return and_(
        Video.status == VideoStatus.COMPLETED,
        or_(Video.visibility != Visibility.PRIVATE, Video.user_id == user_id),
    )
