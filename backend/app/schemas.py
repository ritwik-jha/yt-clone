"""Pydantic request/response models."""

from datetime import datetime
from enum import Enum
from typing import Optional
from pydantic import BaseModel, EmailStr, Field


# ---------- Auth ----------
class SignUpRequest(BaseModel):
    name: str = Field(..., min_length=2, max_length=50)
    email: EmailStr
    password: str = Field(..., min_length=8)


class VerifyOTPRequest(BaseModel):
    email: EmailStr
    otp_code: str = Field(..., min_length=6, max_length=6)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class UserProfileResponse(BaseModel):
    cognito_sub: str
    name: str
    email: EmailStr
    created_at: str


# ---------- Videos ----------
class Visibility(str, Enum):
    PUBLIC = "PUBLIC"
    PRIVATE = "PRIVATE"
    UNLISTED = "UNLISTED"


class VideoStatus(str, Enum):
    PROCESSING = "PROCESSING"
    COMPLETED = "COMPLETED"
    FAILED = "FAILED"


class PresignedUrlResponse(BaseModel):
    url: str
    video_id: str
    key: str


class PresignedThumbnailResponse(BaseModel):
    url: str
    thumbnail_id: str
    key: str


class SaveVideoMetadataRequest(BaseModel):
    title: str = Field(..., min_length=1, max_length=255)
    description: Optional[str] = None
    visibility: Visibility = Visibility.PUBLIC
    video_id: str = Field(..., description="video_id returned by /upload/video/url")
    video_key: str = Field(..., description="S3 key returned by /upload/video/url")
    thumbnail_id: Optional[str] = None
    thumbnail_key: Optional[str] = None


class VideoResponse(BaseModel):
    video_id: str
    title: str
    description: Optional[str] = None
    visibility: Visibility
    status: VideoStatus
    video_key: str
    thumbnail_key: Optional[str] = None
    manifest_uri: Optional[str] = None
    uploader_sub: str
    created_at: str
    updated_at: Optional[str] = None
    error: Optional[str] = None


class ProgressResponse(BaseModel):
    video_id: str
    percent: int
    status: Optional[VideoStatus] = None
