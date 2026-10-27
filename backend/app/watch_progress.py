"""Watch history rules and SQL builders, used by routers/history.py and the
seed script.

No database session or AWS client here, so importing this binds nothing
(tests/support/server.py swaps the clients in before the routers import).
"""

import base64
import binascii
from datetime import datetime, timezone
from uuid import UUID

from sqlalchemy.dialects import postgresql, sqlite

from app.errors import APIError
from app.models import WatchHistory
from app.schemas import ProgressEntryIn

# A video counts as watched to the end at 95 %, or with 10 s or less left.
COMPLETED_FRACTION = 0.95
COMPLETED_REMAINING_SECONDS = 10


def is_completed(position: int, duration: int | None) -> bool:
    if duration is None:
        return False
    return (
        position >= COMPLETED_FRACTION * duration
        or duration - position <= COMPLETED_REMAINING_SECONDS
    )


def utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


# ---------- Cursor ----------
def encode_cursor(last_watched_at: datetime, video_id: UUID) -> str:
    raw = f"{utc(last_watched_at).isoformat()}|{video_id}".encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def decode_cursor(cursor: str) -> tuple[datetime, UUID]:
    try:
        raw = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)).decode()
        ts, video_id = raw.split("|")
        when = datetime.fromisoformat(ts)
        if when.tzinfo is None:
            raise ValueError("naive cursor timestamp")
        return utc(when), UUID(video_id)
    except (ValueError, UnicodeDecodeError, binascii.Error):
        raise APIError(400, "history_cursor_invalid", "History cursor is invalid") from None


# ---------- Writes ----------
def latest_per_video(entries: list[ProgressEntryIn]) -> dict[UUID, ProgressEntryIn]:
    """One entry per video, the latest observation winning, in the order the
    videos first appear. PostgreSQL rejects an ON CONFLICT DO UPDATE that
    touches one row twice, so duplicates go before the statement is built."""
    latest: dict[UUID, ProgressEntryIn] = {}
    for entry in entries:
        kept = latest.get(entry.video_id)
        if kept is None or entry.watched_at >= kept.watched_at:
            latest[entry.video_id] = entry
    return latest


def upsert_statement(dialect: str, rows: list[dict]):
    """INSERT ... ON CONFLICT DO UPDATE for `dialect` ("postgresql" or
    "sqlite"); both support the WHERE on the update."""
    insert = postgresql.insert if dialect == "postgresql" else sqlite.insert
    stmt = insert(WatchHistory).values(rows)
    new = stmt.excluded
    return stmt.on_conflict_do_update(
        index_elements=[WatchHistory.user_id, WatchHistory.video_id],
        set_={
            "position_seconds": new.position_seconds,
            "duration_seconds": new.duration_seconds,
            "completed": new.completed,
            "last_watched_at": new.last_watched_at,
            "updated_at": new.updated_at,
        },
        # Keep the latest observation; an equal one (a retried report)
        # overwrites itself.
        where=WatchHistory.last_watched_at <= new.last_watched_at,
    )
