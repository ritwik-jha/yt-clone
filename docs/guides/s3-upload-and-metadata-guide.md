# S3 Presigned URL Upload & Video Metadata API Implementation Guide

This document captures the end-to-end technical flow, backend FastAPI routes, Pydantic/SQLAlchemy models, and Flutter frontend implementations for generating **S3 Pre-Signed URLs** and saving **Video Metadata** to PostgreSQL.

---

## 1. Architectural Overview & Presigned URL Concept

Uploading high-definition, heavy video files directly through an API gateway server (FastAPI) creates serious memory overhead and bandwidth bottlenecks. To eliminate this bottleneck, a **decoupled direct-to-S3 upload pattern** is utilized:

```
+----------------+      1. GET /upload/video/url       +-------------------+
|                | ----------------------------------> |                   |
|                |                                     |  FastAPI Gateway  |
|                | <---------------------------------- |  (Auth Validation)|
|                |    2. Returns { url, video_id }     +-------------------+
|                |                                               |
| Flutter Client |                                               | Generates via boto3
|  Application   |                                               v
|                |                                     +-------------------+
|                |      3. HTTP PUT (Binary Bytes)     |   Amazon S3       |
|                | ----------------------------------> |   Raw Bucket      |
|                | <---------------------------------- |                   |
|                |          4. HTTP 200 OK             +-------------------+
|                |                                               |
|                |      5. POST /upload/video/save               | Automatically
|                | -----------------------------------\          | Triggers SQS Event
|                |                                    |          v
|                | <----------------------------------/  +-------------------+
|                |    6. Metadata Recorded in DB         | SQS Queue /       |
+----------------+                                       | ECS Transcoder    |
                                                         +-------------------+
```

### **Execution Steps:**
1. **Authentication Check**: The client requests a temporary upload URL from FastAPI, sending its authentication cookie/session token.
2. **Presigned URL Generation**: FastAPI verifies the session, constructs a unique S3 Key (`videos/{user_sub}/{uuid4}.mp4`), and calls `boto3.generate_presigned_url`.
3. **Direct Binary Upload**: The client uses HTTP `PUT` to stream the video bytes directly to the S3 bucket, completely bypassing the FastAPI application server.
4. **Metadata Recording**: Once S3 returns `HTTP 200 OK`, the client calls the FastAPI `/upload/video/save` endpoint to record the video title, description, visibility, and S3 keys into PostgreSQL.
5. **Asynchronous Transcoding**: Meanwhile, S3's `ObjectCreated` event automatically notifies an SQS queue to trigger the background transcoder.

---

## 2. Presigned URL Backend Implementation (FastAPI)

### **FastAPI Upload Router (`routes/upload.py`)**

```python
from fastapi import APIRouter, Depends, HTTPException
import boto3
import uuid
from db.middleware.auth_middleware import get_current_user
from secret_keys import secret_keys

router = APIRouter(prefix="/upload/video", tags=["upload"])

@router.get("/url")
def get_presigned_video_url(user: dict = Depends(get_current_user)):
    """
    Generates a temporary S3 Presigned PUT URL for direct raw video upload.
    """
    try:
        s3_client = boto3.client("s3", region_name=secret_keys.region_name)
        
        # Unique S3 object key combining Cognito Sub and a Random UUID
        video_id = f"videos/{user['sub']}/{str(uuid.uuid4())}.mp4"
        
        presigned_url = s3_client.generate_presigned_url(
            ClientMethod="put_object",
            Params={
                "Bucket": secret_keys.AWS_RAW_VIDEOS_BUCKET,
                "Key": video_id,
                "ContentType": "video/mp4"
            },
            ExpiresIn=3600  # URL valid for 1 hour
        )
        
        return {
            "url": presigned_url,
            "video_id": video_id
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to generate presigned URL: {str(e)}")


@router.get("/url/thumbnail")
def get_presigned_thumbnail_url(user: dict = Depends(get_current_user)):
    """
    Generates a temporary S3 Presigned PUT URL for video thumbnail upload.
    """
    try:
        s3_client = boto3.client("s3", region_name=secret_keys.region_name)
        
        thumbnail_id = f"thumbnails/{user['sub']}/{str(uuid.uuid4())}.jpg"
        
        presigned_url = s3_client.generate_presigned_url(
            ClientMethod="put_object",
            Params={
                "Bucket": secret_keys.AWS_VIDEO_THUMBNAIL_BUCKET,
                "Key": thumbnail_id,
                "ContentType": "image/jpeg"
            },
            ExpiresIn=3600
        )
        
        return {
            "url": presigned_url,
            "thumbnail_id": thumbnail_id
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to generate thumbnail URL: {str(e)}")
```

---

## 3. Video Metadata API & PostgreSQL Schema

### **SQLAlchemy Database Models (`db/models.py`)**

```python
import enum
import uuid
from sqlalchemy import Column, String, Text, Enum, DateTime, ForeignKey, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from db.db import Base

class VisibilityEnum(str, enum.Enum):
    PUBLIC = "PUBLIC"
    PRIVATE = "PRIVATE"
    UNLISTED = "UNLISTED"

class StatusEnum(str, enum.Enum):
    PROCESSING = "PROCESSING"
    COMPLETED = "COMPLETED"
    FAILED = "FAILED"

class Video(Base):
    __tablename__ = "videos"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    title = Column(String(255), nullable=False)
    description = Column(Text, nullable=True)
    visibility = Column(Enum(VisibilityEnum), default=VisibilityEnum.PUBLIC, nullable=False)
    status = Column(Enum(StatusEnum), default=StatusEnum.PROCESSING, nullable=False)
    
    # S3 Object Keys
    video_url = Column(String(512), nullable=False)        # e.g., videos/{user_sub}/{uuid}.mp4
    thumbnail_url = Column(String(512), nullable=True)     # e.g., thumbnails/{user_sub}/{uuid}.jpg
    manifest_url = Column(String(512), nullable=True)      # Populated by transcoder: e.g., processed/{uuid}/master.mpd
    
    # Foreign key link to PostgreSQL User table
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())

    # Relationship mapping
    user = relationship("User", back_populates="videos")
```

### **Pydantic Request & Response Schemas (`schemas/video_schemas.py`)**

```python
from pydantic import BaseModel, Field
from typing import Optional
from datetime import datetime
from uuid import UUID
from db.models import VisibilityEnum, StatusEnum

class SaveVideoMetadataRequest(BaseModel):
    title: str = Field(..., min_length=1, max_length=255)
    description: Optional[str] = None
    visibility: VisibilityEnum = VisibilityEnum.PUBLIC
    video_id: str = Field(..., description="The S3 Key returned by /upload/video/url")
    thumbnail_id: Optional[str] = Field(None, description="The S3 Key returned by /upload/video/url/thumbnail")

class VideoResponse(BaseModel):
    id: UUID
    title: str
    description: Optional[str]
    visibility: VisibilityEnum
    status: StatusEnum
    video_url: str
    thumbnail_url: Optional[str]
    manifest_url: Optional[str]
    created_at: datetime

    class Config:
        from_attributes = True
```

### **FastAPI Save Video Metadata Route (`routes/upload.py`)**

```python
from db.db import get_db
from db.models import User, Video, StatusEnum
from schemas.video_schemas import SaveVideoMetadataRequest, VideoResponse
from sqlalchemy.orm import Session

@router.post("/save", response_model=VideoResponse)
def save_video_metadata(
    data: SaveVideoMetadataRequest,
    db: Session = Depends(get_db),
    user: dict = Depends(get_current_user)
):
    """
    Saves video metadata to PostgreSQL after successful raw S3 upload.
    Initial status is set to PROCESSING until ECS Fargate finishes transcoding.
    """
    # Look up mirrored database user using Cognito Sub
    db_user = db.query(User).filter(User.cognito_sub == user["sub"]).first()
    if not db_user:
        raise HTTPException(status_code=404, detail="User profile not found in database")

    # Create new Video metadata record
    new_video = Video(
        title=data.title,
        description=data.description,
        visibility=data.visibility,
        status=StatusEnum.PROCESSING,  # Background transcoder will update to COMPLETED
        video_url=data.video_id,
        thumbnail_url=data.thumbnail_id,
        user_id=db_user.id
    )

    db.add(new_video)
    db.commit()
    db.refresh(new_video)

    return new_video
```

---

## 4. Frontend (Flutter) Implementation

### **Upload Video Service (`upload_video_service.dart`)**

```dart
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class UploadVideoService {
  final String baseUrl = "http://192.168.1.10:8000/upload/video";

  /// 1. Request Presigned Upload URLs for Video and Thumbnail
  Future<Map<String, String>> getPresignedUrl({
    required String cookieHeader,
    required bool isThumbnail,
  }) async {
    final endpoint = isThumbnail ? "$baseUrl/url/thumbnail" : "$baseUrl/url";
    final response = await http.get(
      Uri.parse(endpoint),
      headers: {
        "Content-Type": "application/json",
        "Cookie": cookieHeader,
      },
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (isThumbnail) {
        return {
          "url": data["url"],
          "id": data["thumbnail_id"],
        };
      } else {
        return {
          "url": data["url"],
          "id": data["video_id"],
        };
      }
    } else {
      throw Exception("Failed to get presigned URL: ${response.body}");
    }
  }

  /// 2. Direct HTTP PUT Binary Upload to Amazon S3
  Future<bool> uploadFileToS3({
    required String presignedUrl,
    required File file,
    required String contentType, // "video/mp4" or "image/jpeg"
  }) async {
    final fileBytes = await file.readAsBytes();
    final response = await http.put(
      Uri.parse(presignedUrl),
      headers: {
        "Content-Type": contentType,
      },
      body: fileBytes,
    );

    return response.statusCode == 200;
  }

  /// 3. Save Video Metadata to FastAPI Backend / PostgreSQL
  Future<Map<String, dynamic>> saveVideoMetadata({
    required String cookieHeader,
    required String title,
    required String description,
    required String visibility, // "PUBLIC", "PRIVATE", "UNLISTED"
    required String videoId,
    required String? thumbnailId,
  }) async {
    final response = await http.post(
      Uri.parse("$baseUrl/save"),
      headers: {
        "Content-Type": "application/json",
        "Cookie": cookieHeader,
      },
      body: jsonEncode({
        "title": title,
        "description": description,
        "visibility": visibility,
        "video_id": videoId,
        "thumbnail_id": thumbnailId,
      }),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception("Failed to save video metadata: ${response.body}");
    }
  }
}
```
