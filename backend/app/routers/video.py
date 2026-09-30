"""Video APIs — public feed, my videos, one video, live progress, view
counting, and owner edit/delete.

Visibility rules: anyone may read a COMPLETED video that is PUBLIC or
UNLISTED; only the owner may read a PRIVATE one or one that is not finished
yet. Everyone else gets 404, so a private video's existence does not leak.
Edit and delete are owner-only and answer 404 to everyone else for the same
reason. The feed lists PUBLIC + COMPLETED only.

Playback and thumbnail URLs are derived from the stored S3 keys at read time,
so moving a CloudFront distribution needs no data migration.

No handler here writes `status`: the completion poller owns every transition
after POST /upload/video/save.
"""

import logging
from pathlib import PurePosixPath
from typing import Annotated
from uuid import UUID

import redis
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import APIRouter, BackgroundTasks, Depends, Query, Request, Response, status
from sqlalchemy import ColumnElement, func, select, update
from sqlalchemy.orm import Session, joinedload

from app import cache
from app.clients import redis_client, s3
from app.config import get_settings
from app.db import get_db
from app.deps import get_current_user, get_optional_identity
from app.errors import APIError
from app.models import User, Video, VideoStatus, Visibility
from app.schemas import (
    Creator, CreatorDetail, FeedItem, FeedResponse, MyVideosResponse,
    ProgressResponse, UpdateVideoRequest, VideoDetail,
)

log = logging.getLogger(__name__)

router = APIRouter(prefix="/video", tags=["video"])

PageParam = Annotated[int, Query(ge=1, le=100_000)]
LimitParam = Annotated[int, Query(ge=1, le=50)]


def _not_found() -> APIError:
    return APIError(404, "video_not_found", "Video not found")


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
        "hls_url":          _manifest_url(video.hls_manifest_s3_key),
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


def _load(db: Session, video_id: UUID) -> Video | None:
    return db.scalar(
        select(Video).options(joinedload(Video.user)).where(Video.id == video_id)
    )


def _load_for_viewer(db: Session, video_id: UUID, request: Request) -> Video:
    video = _load(db, video_id)
    if video is None:
        raise _not_found()
    if _publicly_viewable(video):
        return video
    # Only resolve the caller when ownership decides the answer; public
    # reads never cost a Cognito call.
    identity = get_optional_identity(request)
    if identity is None or identity.sub != video.user.cognito_sub:
        raise _not_found()
    return video


def _load_owned(db: Session, video_id: UUID, user: User) -> Video:
    video = _load(db, video_id)
    if video is None or video.user_id != user.id:
        raise _not_found()
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


def _delete_media(raw_key: str, thumbnail_key: str) -> None:
    """Best-effort removal of a deleted video's S3 objects: the raw upload,
    the thumbnail, and everything the transcoder wrote under <VIDEO_ID>/ in
    the processed bucket. Runs after the response; failures are logged and
    leave orphaned objects, never a half-deleted row."""
    s = get_settings()
    for bucket, key in (
        (s.s3_raw_videos_bucket, raw_key),
        (s.s3_thumbnails_bucket, thumbnail_key),
    ):
        try:
            s3().delete_object(Bucket=bucket, Key=key)
        except (BotoCoreError, ClientError) as exc:
            log.error("deleting s3://%s/%s failed: %s", bucket, key, exc)

    # The transcoder's VIDEO_ID is the raw key's stem, a UUID minted by
    # GET /upload/video/url, so the prefix cannot match another video.
    prefix = f"{PurePosixPath(raw_key).stem}/"
    try:
        pages = s3().get_paginator("list_objects_v2").paginate(
            Bucket=s.s3_processed_bucket, Prefix=prefix,
        )
        for page in pages:
            # A page holds at most 1000 keys, the delete_objects limit.
            objects = [{"Key": o["Key"]} for o in page.get("Contents", [])]
            if not objects:
                continue
            resp = s3().delete_objects(
                Bucket=s.s3_processed_bucket,
                Delete={"Objects": objects, "Quiet": True},
            )
            for err in resp.get("Errors", []):
                log.error(
                    "deleting s3://%s/%s failed: %s",
                    s.s3_processed_bucket, err.get("Key"), err.get("Code"),
                )
    except (BotoCoreError, ClientError) as exc:
        log.error("deleting s3://%s/%s failed: %s", s.s3_processed_bucket, prefix, exc)


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


@router.patch("/{video_id}", response_model=VideoDetail)
def update_video(
    video_id: UUID,
    data: UpdateVideoRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    video = _load_owned(db, video_id, user)
    for field in data.model_fields_set:
        setattr(video, field, getattr(data, field))
    db.commit()
    # A GET that read the old row just before this commit can still re-cache
    # it; that entry lives at most VIDEO_META_CACHE_TTL_SECONDS.
    cache.drop_video(video.id)
    return _to_detail(video)


@router.delete("/{video_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_video(
    video_id: UUID,
    background_tasks: BackgroundTasks,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    video = _load_owned(db, video_id, user)
    raw_key, thumbnail_key = video.s3_key, video.thumbnail_s3_key
    db.delete(video)
    db.commit()
    cache.drop_video(video_id)
    background_tasks.add_task(_delete_media, raw_key, thumbnail_key)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/{video_id}/progress", response_model=ProgressResponse)
def get_video_progress(video_id: UUID, request: Request, db: Session = Depends(get_db)):
    """Transcode progress (0-100). The Redis key only exists while the
    transcoder runs and for a while after, so a finished video reports 100
    from its row."""
    video = _load_for_viewer(db, video_id, request)
    percent = 100 if video.status == VideoStatus.COMPLETED else _read_progress(video.s3_key)
    return ProgressResponse(video_id=video.id, percent=percent, status=video.status)


@router.post("/{video_id}/view", status_code=status.HTTP_204_NO_CONTENT)
def record_view(video_id: UUID, request: Request, db: Session = Depends(get_db)):
    """Count one playback. Clients call it once per play session; there is
    no per-viewer dedupe. A cached GET /video/{id} can lag the new count by
    up to VIDEO_META_CACHE_TTL_SECONDS."""
    video = _load_for_viewer(db, video_id, request)
    if video.status != VideoStatus.COMPLETED:
        raise APIError(409, "video_not_ready", "Video is not ready to play")
    db.execute(
        update(Video)
        .where(Video.id == video.id)
        # A view is not an edit, so updated_at keeps its value.
        .values(views_count=Video.views_count + 1, updated_at=Video.updated_at)
        .execution_options(synchronize_session=False)
    )
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
