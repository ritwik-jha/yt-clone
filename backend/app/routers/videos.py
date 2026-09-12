"""Video read APIs — GET single video, list my videos, GET live progress."""

from fastapi import APIRouter, Depends, HTTPException
from boto3.dynamodb.conditions import Key

from app.clients import redis_client, videos_table
from app.config import get_settings
from app.deps import get_current_user
from app.schemas import ProgressResponse, VideoResponse, VideoStatus, Visibility

router = APIRouter(prefix="/videos", tags=["videos"])


def _item_to_response(row: dict) -> VideoResponse:
    return VideoResponse(
        video_id=row["video_id"],
        title=row["title"],
        description=row.get("description") or None,
        visibility=Visibility(row["visibility"]),
        status=VideoStatus(row["status"]),
        video_key=row["video_key"],
        thumbnail_key=row.get("thumbnail_key") or None,
        manifest_uri=row.get("manifest_uri") or None,
        uploader_sub=row["uploader_sub"],
        created_at=row["created_at"],
        updated_at=row.get("updated_at"),
        error=row.get("error") or None,
    )


@router.get("/mine", response_model=list[VideoResponse])
def list_my_videos(user=Depends(get_current_user)):
    resp = videos_table().query(
        IndexName="uploader-created-index",
        KeyConditionExpression=Key("uploader_sub").eq(user["sub"]),
        ScanIndexForward=False,  # newest first
    )
    return [_item_to_response(r) for r in resp.get("Items", [])]


@router.get("/{video_id}", response_model=VideoResponse)
def get_video(video_id: str):
    row = videos_table().get_item(Key={"video_id": video_id}).get("Item")
    if not row:
        raise HTTPException(status_code=404, detail="Video not found")
    return _item_to_response(row)


@router.get("/{video_id}/progress", response_model=ProgressResponse)
def get_video_progress(video_id: str):
    """Read live transcode progress from Redis (0-100)."""
    s = get_settings()
    key = f"{s.redis_progress_prefix}:{video_id}"
    raw = redis_client().get(key)
    percent = int(raw) if raw is not None else 0

    row = videos_table().get_item(Key={"video_id": video_id}).get("Item") or {}
    status_val = row.get("status")
    status_enum = VideoStatus(status_val) if status_val else None

    return ProgressResponse(video_id=video_id, percent=percent, status=status_enum)
