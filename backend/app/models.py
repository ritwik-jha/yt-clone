"""ORM models for the users and videos tables.

The schema itself is owned by the Alembic revisions in migrations/versions;
keep these models and the latest revision in step (`alembic check` fails if
they drift).
"""

import enum
import uuid
from datetime import datetime

from sqlalchemy import (
    BigInteger, DateTime, Enum, ForeignKey, Integer, MetaData, String, Text,
    func, text,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Visibility(str, enum.Enum):
    PUBLIC = "PUBLIC"
    PRIVATE = "PRIVATE"
    UNLISTED = "UNLISTED"


class VideoStatus(str, enum.Enum):
    PENDING = "PENDING"
    PROCESSING = "PROCESSING"
    COMPLETED = "COMPLETED"
    FAILED = "FAILED"


class Base(DeclarativeBase):
    metadata = MetaData(naming_convention={
        "pk": "pk_%(table_name)s",
        "uq": "uq_%(table_name)s_%(column_0_name)s",
        "ix": "ix_%(table_name)s_%(column_0_name)s",
        "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
        "ck": "ck_%(table_name)s_%(constraint_name)s",
    })


def _updated_at() -> Mapped[datetime]:
    return mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(),
    )


class User(Base):
    """Profile mirror of a Cognito user. Cognito keeps the credentials."""

    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(
        primary_key=True, default=uuid.uuid4, server_default=text("gen_random_uuid()"),
    )
    name: Mapped[str] = mapped_column(String(100))
    email: Mapped[str] = mapped_column(String(255), unique=True)
    cognito_sub: Mapped[str] = mapped_column(String(255), unique=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(),
    )
    updated_at: Mapped[datetime] = _updated_at()

    videos: Mapped[list["Video"]] = relationship(
        back_populates="user", passive_deletes=True,
    )


class Video(Base):
    __tablename__ = "videos"

    id: Mapped[uuid.UUID] = mapped_column(
        primary_key=True, default=uuid.uuid4, server_default=text("gen_random_uuid()"),
    )
    title: Mapped[str] = mapped_column(String(150), index=True)
    description: Mapped[str | None] = mapped_column(Text)
    # Raw upload key in the pipeline's raw bucket. The poller matches
    # transcoder messages on it (their raw_key), and its filename stem is the
    # transcoder's VIDEO_ID, which names the Redis progress key.
    s3_key: Mapped[str] = mapped_column(String(500), unique=True)
    thumbnail_s3_key: Mapped[str] = mapped_column(String(500))
    # Key in the processed bucket; the API serves it through CloudFront.
    dash_manifest_s3_key: Mapped[str | None] = mapped_column(String(500))
    visibility: Mapped[Visibility] = mapped_column(
        Enum(Visibility, name="visibility_enum"),
        default=Visibility.PUBLIC, server_default=Visibility.PUBLIC.value, index=True,
    )
    status: Mapped[VideoStatus] = mapped_column(
        Enum(VideoStatus, name="status_enum"),
        default=VideoStatus.PENDING, server_default=VideoStatus.PENDING.value, index=True,
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True,
    )
    views_count: Mapped[int] = mapped_column(
        BigInteger, default=0, server_default=text("0"),
    )
    duration_seconds: Mapped[int | None] = mapped_column(Integer)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), index=True,
    )
    updated_at: Mapped[datetime] = _updated_at()

    user: Mapped[User] = relationship(back_populates="videos")
