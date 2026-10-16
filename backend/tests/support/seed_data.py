"""Deterministic records for the SQLite test database.

scripts/seed_sqlite.py writes them, the fake Cognito in tests/support/fakes.py
knows the same accounts, and the integration and E2E tests assert against
them. Change them here only.
"""

import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from app.models import VideoStatus, Visibility

# Every code the fake Cognito sends (sign-up confirmation, password reset).
OTP = "123456"
PASSWORD = "Passw0rd!"

_NS = uuid.UUID("6f1d4c2e-3a5b-4c7d-9e8f-0a1b2c3d4e5f")
_EPOCH = datetime(2026, 1, 1, tzinfo=timezone.utc)


def _id(name: str) -> uuid.UUID:
    return uuid.uuid5(_NS, name)


@dataclass(frozen=True)
class SeedUser:
    key: str
    name: str
    email: str
    confirmed: bool = True

    @property
    def id(self) -> uuid.UUID:
        return _id(f"user:{self.key}")

    @property
    def sub(self) -> str:
        return str(_id(f"sub:{self.key}"))


@dataclass(frozen=True)
class SeedVideo:
    key: str
    owner: str
    title: str
    visibility: Visibility
    status: VideoStatus
    age_days: int
    views: int = 0
    duration: int | None = 120

    @property
    def id(self) -> uuid.UUID:
        return _id(f"video:{self.key}")

    @property
    def stem(self) -> uuid.UUID:
        return _id(f"stem:{self.key}")

    @property
    def created_at(self) -> datetime:
        return _EPOCH - timedelta(days=self.age_days)


ALICE = SeedUser("alice", "Alice Tester", "alice@example.com")
BOB = SeedUser("bob", "Bob Tester", "bob@example.com")
# Exists in Cognito but never confirmed: login must fail.
CAROL = SeedUser("carol", "Carol Pending", "carol@example.com", confirmed=False)
USERS = [ALICE, BOB, CAROL]
USERS_BY_KEY = {u.key: u for u in USERS}

_P, _U, _X = Visibility.PUBLIC, Visibility.UNLISTED, Visibility.PRIVATE
_C, _R, _F = VideoStatus.COMPLETED, VideoStatus.PROCESSING, VideoStatus.FAILED

VIDEOS = [
    SeedVideo("mountains", "alice", "Hiking the Western Ghats", _P, _C, 1, views=42, duration=615),
    SeedVideo("cooking", "alice", "Ten-minute dal tadka", _P, _C, 3, views=7, duration=598),
    SeedVideo("guitar", "bob", "Fingerstyle guitar basics", _P, _C, 2, views=1300, duration=1830),
    SeedVideo("timelapse", "bob", "City timelapse at night", _P, _C, 5, views=0, duration=45),
    SeedVideo("drafts", "alice", "Unlisted behind the scenes", _U, _C, 4, views=3),
    SeedVideo("diary", "alice", "Private video diary", _X, _C, 6),
    SeedVideo("rendering", "alice", "Still transcoding", _P, _R, 0, duration=None),
    SeedVideo("broken", "bob", "Upload that failed", _P, _F, 7, duration=None),
]
VIDEOS_BY_KEY = {v.key: v for v in VIDEOS}

# The public feed: PUBLIC + COMPLETED, newest first.
FEED = sorted(
    (v for v in VIDEOS if v.visibility == _P and v.status == _C),
    key=lambda v: v.created_at, reverse=True,
)


def s3_key(video: SeedVideo) -> str:
    return f"videos/{USERS_BY_KEY[video.owner].sub}/{video.stem}.mp4"


def thumbnail_key(video: SeedVideo) -> str:
    return f"thumbnails/{USERS_BY_KEY[video.owner].sub}/{video.stem}"
