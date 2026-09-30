"""Pydantic request/response models (docs/api-and-db-schema-spec.md)."""

import re
from datetime import datetime
from typing import Annotated, Optional
from uuid import UUID

from pydantic import (
    BaseModel, ConfigDict, EmailStr, Field, StringConstraints, field_validator,
)

from app.models import VideoStatus, Visibility


# Cognito matches email usernames case-insensitively; storing one form keeps
# the users.email unique constraint meaningful.
Email = Annotated[EmailStr, Field(max_length=255)]


def _lower(value: str) -> str:
    return value.lower()


Password = Annotated[str, Field(min_length=8, max_length=256)]
OTP = Annotated[str, StringConstraints(pattern=r"^[0-9]{6}$")]


def _strength(value: str) -> str:
    # The spec's rules plus a lowercase letter, which the Cognito pool
    # policy also requires; checking here gives a clearer 400.
    for pattern, what in (
        (r"[A-Z]", "an uppercase letter"),
        (r"[a-z]", "a lowercase letter"),
        (r"[0-9]", "a number"),
        (r"[^A-Za-z0-9]", "a special character"),
    ):
        if not re.search(pattern, value):
            raise ValueError(f"password must contain {what}")
    return value


class MessageResponse(BaseModel):
    message: str


# ---------- Auth ----------
class SignUpRequest(BaseModel):
    name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=2, max_length=50)]
    email: Email
    password: Password

    _email = field_validator("email")(_lower)
    _password = field_validator("password")(_strength)


class VerifyOTPRequest(BaseModel):
    email: Email
    otp: OTP

    _email = field_validator("email")(_lower)


class EmailRequest(BaseModel):
    """Body of POST /auth/resend-otp and POST /auth/forgot-password."""

    email: Email

    _email = field_validator("email")(_lower)


class ResetPasswordRequest(BaseModel):
    email: Email
    otp: OTP
    new_password: Password

    _email = field_validator("email")(_lower)
    _password = field_validator("new_password")(_strength)


class LoginRequest(BaseModel):
    email: Email
    password: str = Field(..., min_length=1, max_length=256)

    _email = field_validator("email")(_lower)


class UserProfileResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    email: str
    cognito_sub: str
    created_at: datetime


# ---------- Upload ----------
class PresignedUrlResponse(BaseModel):
    url: str
    video_id: str = Field(..., description="Raw S3 key: videos/{user_sub}/{uuid}.mp4")


class PresignedThumbnailResponse(BaseModel):
    url: str
    thumbnail_id: str = Field(..., description="Thumbnail S3 key: thumbnails/{user_sub}/{uuid}")


Title = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=100)]
Description = Annotated[str, StringConstraints(strip_whitespace=True, max_length=1000)]


def _blank_is_none(value: Optional[str]) -> Optional[str]:
    return value or None


def _upper(value):
    return value.upper() if isinstance(value, str) else value


class SaveVideoRequest(BaseModel):
    title: Title
    description: Optional[Description] = None
    s3_key: str = Field(..., max_length=500)
    thumbnail_s3_key: str = Field(..., max_length=500)
    visibility: Visibility

    _description = field_validator("description")(_blank_is_none)
    _visibility = field_validator("visibility", mode="before")(_upper)


class SaveVideoResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    title: str
    status: VideoStatus
    visibility: Visibility
    created_at: datetime


# ---------- Video ----------
class Creator(BaseModel):
    id: UUID
    name: str


class CreatorDetail(Creator):
    created_at: datetime


class UpdateVideoRequest(BaseModel):
    """PATCH /video/{id}. Omitted fields are left alone; description null or
    "" clears it. Title and visibility can be omitted but not null."""

    title: Optional[Title] = None
    description: Optional[Description] = None
    visibility: Optional[Visibility] = None

    _description = field_validator("description")(_blank_is_none)
    _visibility = field_validator("visibility", mode="before")(_upper)

    @field_validator("title", "visibility")
    @classmethod
    def _not_null(cls, value):
        if value is None:
            raise ValueError("may be omitted but not null")
        return value


class FeedItem(BaseModel):
    id: UUID
    title: str
    description: Optional[str] = None
    thumbnail_url: str
    # Null until the transcoder has produced the manifest (owner views only).
    manifest_url: Optional[str] = None
    # HLS master playlist over the same segments, for players without DASH
    # (AVPlayer on iOS). Also null for videos transcoded before HLS output.
    hls_url: Optional[str] = None
    views_count: int
    duration_seconds: Optional[int] = None
    creator: Creator
    created_at: datetime


class VideoDetail(FeedItem):
    creator: CreatorDetail
    visibility: Visibility
    status: VideoStatus


class FeedResponse(BaseModel):
    total: int
    page: int
    limit: int
    items: list[FeedItem]


class MyVideosResponse(BaseModel):
    total: int
    page: int
    limit: int
    items: list[VideoDetail]


class ProgressResponse(BaseModel):
    video_id: UUID
    percent: int
    status: VideoStatus
