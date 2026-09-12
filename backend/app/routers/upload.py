"""Presigned URL generation + video metadata save."""

import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException

from app.clients import s3, videos_table
from app.config import get_settings
from app.deps import get_current_user
from app.schemas import (
    PresignedThumbnailResponse, PresignedUrlResponse,
    SaveVideoMetadataRequest, VideoResponse, VideoStatus, Visibility,
)

router = APIRouter(prefix="/upload/video", tags=["upload"])


@router.get("/url", response_model=PresignedUrlResponse)
def get_video_upload_url(user=Depends(get_current_user)):
    s = get_settings()
    video_id = str(uuid.uuid4())
    key = f"videos/{user['sub']}/{video_id}.mp4"
    try:
        url = s3().generate_presigned_url(
            ClientMethod="put_object",
            Params={
                "Bucket":      s.s3_raw_videos_bucket,
                "Key":         key,
                "ContentType": "video/mp4",
            },
            ExpiresIn=s.presigned_url_ttl_seconds,
        )
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))
    return PresignedUrlResponse(url=url, video_id=video_id, key=key)


@router.get("/url/thumbnail", response_model=PresignedThumbnailResponse)
def get_thumbnail_upload_url(user=Depends(get_current_user)):
    s = get_settings()
    thumbnail_id = str(uuid.uuid4())
    key = f"thumbnails/{user['sub']}/{thumbnail_id}.jpg"
    try:
        url = s3().generate_presigned_url(
            ClientMethod="put_object",
            Params={
                "Bucket":      s.s3_thumbnails_bucket,
                "Key":         key,
                "ContentType": "image/jpeg",
            },
            ExpiresIn=s.presigned_url_ttl_seconds,
        )
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))
    return PresignedThumbnailResponse(url=url, thumbnail_id=thumbnail_id, key=key)


@router.post("/save", response_model=VideoResponse)
def save_video_metadata(
    data: SaveVideoMetadataRequest,
    user=Depends(get_current_user),
):
    now = datetime.now(timezone.utc).isoformat()
    item = {
        "video_id":     data.video_id,
        "title":        data.title,
        "description":  data.description or "",
        "visibility":   data.visibility.value,
        "status":       VideoStatus.PROCESSING.value,
        "video_key":    data.video_key,
        "thumbnail_key": data.thumbnail_key or "",
        "manifest_uri": "",
        "uploader_sub": user["sub"],
        "created_at":   now,
        "updated_at":   now,
    }
    videos_table().put_item(
        Item=item,
        ConditionExpression="attribute_not_exists(video_id)",
    )
    return VideoResponse(
        video_id=item["video_id"],
        title=item["title"],
        description=item["description"],
        visibility=Visibility(item["visibility"]),
        status=VideoStatus(item["status"]),
        video_key=item["video_key"],
        thumbnail_key=item["thumbnail_key"] or None,
        manifest_uri=None,
        uploader_sub=item["uploader_sub"],
        created_at=item["created_at"],
        updated_at=item["updated_at"],
    )
