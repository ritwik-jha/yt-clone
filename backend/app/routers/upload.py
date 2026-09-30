"""Presigned upload URLs + video metadata save.

The keys are minted here and embed the caller's Cognito sub, so /save only
accepts keys this user could have been issued.
"""

import logging
import re
import uuid

from botocore.exceptions import BotoCoreError, ClientError
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.clients import s3
from app.config import get_settings
from app.db import get_db
from app.deps import Identity, get_current_user, get_identity
from app.models import User, Video, VideoStatus
from app.schemas import (
    PresignedThumbnailResponse, PresignedUrlResponse, SaveVideoRequest,
    SaveVideoResponse,
)

log = logging.getLogger(__name__)

router = APIRouter(prefix="/upload/video", tags=["upload"])

_UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"


def _presign(bucket: str, key: str, content_type: str) -> str:
    try:
        return s3().generate_presigned_url(
            ClientMethod="put_object",
            Params={"Bucket": bucket, "Key": key, "ContentType": content_type},
            ExpiresIn=get_settings().presigned_url_ttl_seconds,
        )
    except (BotoCoreError, ClientError):
        log.exception("presigning an upload URL failed")
        raise HTTPException(500, "Could not create an upload URL") from None


@router.get("/url", response_model=PresignedUrlResponse)
def get_video_upload_url(identity: Identity = Depends(get_identity)):
    # The raw bucket's S3 notification only fires for .mp4 keys, and the
    # transcoder takes its VIDEO_ID from this filename stem.
    key = f"videos/{identity.sub}/{uuid.uuid4()}.mp4"
    url = _presign(get_settings().s3_raw_videos_bucket, key, "video/mp4")
    return PresignedUrlResponse(url=url, video_id=key)


@router.get("/url/thumbnail", response_model=PresignedThumbnailResponse)
def get_thumbnail_upload_url(identity: Identity = Depends(get_identity)):
    key = f"thumbnails/{identity.sub}/{uuid.uuid4()}"
    url = _presign(get_settings().s3_thumbnails_bucket, key, "image/jpeg")
    return PresignedThumbnailResponse(url=url, thumbnail_id=key)


@router.post("/save", response_model=SaveVideoResponse, status_code=status.HTTP_201_CREATED)
def save_video_metadata(
    data: SaveVideoRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    sub = re.escape(user.cognito_sub)
    if not re.fullmatch(rf"videos/{sub}/{_UUID}\.mp4", data.s3_key):
        raise HTTPException(400, "s3_key must be a video_id issued by GET /upload/video/url")
    if not re.fullmatch(rf"thumbnails/{sub}/{_UUID}", data.thumbnail_s3_key):
        raise HTTPException(400, "thumbnail_s3_key must be a thumbnail_id issued by GET /upload/video/url/thumbnail")

    video = Video(
        title=data.title,
        description=data.description,
        s3_key=data.s3_key,
        thumbnail_s3_key=data.thumbnail_s3_key,
        visibility=data.visibility,
        status=VideoStatus.PENDING,
        user_id=user.id,
    )
    db.add(video)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, "This upload has already been saved") from None
    return video
