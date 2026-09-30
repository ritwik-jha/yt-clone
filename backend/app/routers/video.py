"""Video read APIs — public feed, my videos, one video, live progress.

Visibility rules: anyone may read a COMPLETED video that is PUBLIC or
UNLISTED; only the owner may read a PRIVATE one or one that is not finished
yet. Everyone else gets 404, so a private video's existence does not leak.
The feed lists PUBLIC + COMPLETED only.

Playback and thumbnail URLs are derived from the stored S3 keys at read time,
so moving a CloudFront distribution needs no data migration.
"""

import logging
from pathlib import PurePosixPath
from typing import Annotated
from uuid import UUID

import redis
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy import ColumnElement, func, select
from sqlalchemy.orm import Session, joinedload

from app import cache
from app.clients import redis_client
from app.config import get_settings
from app.db import get_db
from app.deps import get_current_user, get_optional_identity
from app.models import User, Video, VideoStatus, Visibility
from app.schemas import (
    Creator, CreatorDetail, FeedItem, FeedResponse, MyVideosResponse,
    ProgressResponse, VideoDetail,
)

log = logging.getLogger(__name__)

router = APIRouter(prefix="/video", tags=["video"])

PageParam = Annotated[int, Query(ge=1, le=100_000)]
LimitParam = Annotated[int, Query(ge=1, le=50)]


def _thumbnail_url(key: str) -> str:
    return f"https://{get_settings().thumbnails_cdn_domain}/{key}"


def _manifest_url(key: str | None) -> str | None:
    return f"https://{get_settings().cloudfront_domain}/{key}" if key else None


def _feed_fields(video: Video) -> dict:
    return {
        "id":               video.id,
        "title":            video.title,
        "description":      video.description,
        "thumbnail_url":    _thumbnail_url(video.thumbnail_s3_key),
        "manifest_url":     _manifest_url(video.dash_manifest_s3_key),
        "views_count":      video.views_count,
        "duration_seconds": video.duration_seconds,
        "created_at":       video.created_at,
    }


def _to_feed_item(video: Video) -> FeedItem:
    return FeedItem(
        **_feed_fields(video),
        creator=Creator(id=video.user.id, name=video.user.name),
    )


def _to_detail(video: Video) -> VideoDetail:
    return VideoDetail(
        **_feed_fields(video),
        creator=CreatorDetail(
            id=video.user.id, name=video.user.name, created_at=video.user.created_at,
        ),
        visibility=video.visibility,
        status=video.status,
    )


def _publicly_viewable(video: Video) -> bool:
    return video.status == VideoStatus.COMPLETED and video.visibility != Visibility.PRIVATE


def _page(db: Session, where: ColumnElement[bool], page: int, limit: int) -> tuple[int, list[Video]]:
    total = db.scalar(select(func.count()).select_from(Video).where(where))
    rows = db.scalars(
        select(Video)
        .options(joinedload(Video.user))
        .where(where)
        .order_by(Video.created_at.desc(), Video.id.desc())
        .offset((page - 1) * limit)
        .limit(limit)
    ).all()
    return total, list(rows)


def _load_for_viewer(db: Session, video_id: UUID, request: Request) -> Video:
    video = db.scalar(
        select(Video).options(joinedload(Video.user)).where(Video.id == video_id)
    )
    if video is None:
        raise HTTPException(404, "Video not found")
    if _publicly_viewable(video):
        return video
    # Only resolve the caller when ownership decides the answer; public
    # reads never cost a Cognito call.
    identity = get_optional_identity(request)
    if identity is None or identity.sub != video.user.cognito_sub:
        raise HTTPException(404, "Video not found")
    return video


def _read_progress(s3_key: str) -> int:
    # The transcoder names the key after its VIDEO_ID, the raw key's stem.
    key = f"{get_settings().redis_progress_prefix}:{PurePosixPath(s3_key).stem}"
    try:
        raw = redis_client().get(key)
    except redis.RedisError as exc:
        log.warning("progress read failed: %s", exc)
        return 0
    try:
        return max(0, min(100, int(raw))) if raw is not None else 0
    except ValueError:
        return 0


# Static paths first: /{video_id} would otherwise capture "feed" and "mine".

@router.get("/feed", response_model=FeedResponse)
def get_feed(page: PageParam = 1, limit: LimitParam = 10, db: Session = Depends(get_db)):
    where = (Video.visibility == Visibility.PUBLIC) & (Video.status == VideoStatus.COMPLETED)
    total, rows = _page(db, where, page, limit)
    return FeedResponse(
        total=total, page=page, limit=limit, items=[_to_feed_item(v) for v in rows],
    )


@router.get("/mine", response_model=MyVideosResponse)
def list_my_videos(
    page: PageParam = 1,
    limit: LimitParam = 10,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    total, rows = _page(db, Video.user_id == user.id, page, limit)
    return MyVideosResponse(
        total=total, page=page, limit=limit, items=[_to_detail(v) for v in rows],
    )


@router.get("/{video_id}", response_model=VideoDetail)
def get_video(video_id: UUID, request: Request, db: Session = Depends(get_db)):
    cached = cache.get_video(video_id)
    if cached is not None:
        return cached
    video = _load_for_viewer(db, video_id, request)
    detail = _to_detail(video)
    if _publicly_viewable(video):
        cache.put_video(detail)
    return detail


@router.get("/{video_id}/progress", response_model=ProgressResponse)
def get_video_progress(video_id: UUID, request: Request, db: Session = Depends(get_db)):
    """Transcode progress (0-100). The Redis key only exists while the
    transcoder runs and for a while after, so a finished video reports 100
    from its row."""
    video = _load_for_viewer(db, video_id, request)
    percent = 100 if video.status == VideoStatus.COMPLETED else _read_progress(video.s3_key)
    return ProgressResponse(video_id=video.id, percent=percent, status=video.status)
