"""Watch history: per-user progress on each video, synced across browsers.

One row per (user, video) holds the latest progress. Browsers report
positions with the time they observed them (`watched_at`), and the server
keeps the report with the latest observation, not the latest arrival: a
report flushed late, after a network drop or on the next visit, never
overwrites newer progress from another browser. `watched_at` is clamped to
the server clock so a machine whose clock runs fast can't pin its entry.

Every query here runs on PostgreSQL and on SQLite (the tests): the upsert is
built for the connection's dialect, `now` is taken in Python, and every
timestamp is written in UTC. SQLite keeps no offset, so values read back
from it are naive and `utc` reattaches UTC. The rules and SQL builders live
in app/watch_progress.py.

Rows for videos the caller can no longer watch (made private by their owner,
or not COMPLETED) are kept but hidden on read, so they come back if the
video does. Deleting a video deletes its rows (ON DELETE CASCADE).
"""

from datetime import datetime, timedelta, timezone
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response, status
from sqlalchemy import delete, select, tuple_
from sqlalchemy.orm import Session, contains_eager

from app.db import get_db
from app.deps import get_current_user
from app.errors import APIError
from app.models import User, Video, WatchHistory
from app.schemas import (
    MAX_MEDIA_SECONDS, HistoryItem, HistoryResponse, PositionsResponse,
    ProgressResult, RecordProgressRequest, RecordProgressResponse,
    WatchProgress,
)
from app.video_views import to_feed_item, viewable_by
from app.watch_progress import (
    decode_cursor, encode_cursor, is_completed, latest_per_video, upsert_statement, utc,
)

router = APIRouter(prefix="/history", tags=["history"])

# Reports observed longer ago than this are answered `expired`, not stored.
MAX_REPORT_AGE = timedelta(days=30)
MAX_IDS = 50


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _progress(row: WatchHistory) -> WatchProgress:
    return WatchProgress(
        video_id=row.video_id,
        position_seconds=row.position_seconds,
        duration_seconds=row.duration_seconds,
        completed=row.completed,
        last_watched_at=utc(row.last_watched_at),
    )


def _rows_for(db: Session, user_id: UUID, video_ids) -> dict[UUID, WatchHistory]:
    rows = db.scalars(
        select(WatchHistory)
        .where(WatchHistory.user_id == user_id, WatchHistory.video_id.in_(video_ids))
        # The session keeps objects across commits (expire_on_commit=False);
        # always read what the upsert left.
        .execution_options(populate_existing=True)
    ).all()
    return {r.video_id: r for r in rows}


# Static paths before /{video_id}, as in routers/video.py.

@router.post("/progress", response_model=RecordProgressResponse)
def record_progress(
    data: RecordProgressRequest,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Record a batch of progress reports. Each entry gets its own result,
    so one bad video or old report never fails the batch."""
    now = _now()
    latest = latest_per_video(data.entries)
    durations = dict(db.execute(
        select(Video.id, Video.duration_seconds)
        .where(Video.id.in_(latest), viewable_by(user.id))
    ).all())

    results: dict[UUID, str] = {}
    observed: dict[UUID, datetime] = {}
    rows = []
    for video_id, entry in latest.items():
        if entry.watched_at < now - MAX_REPORT_AGE:
            results[video_id] = "expired"
            continue
        if video_id not in durations:
            results[video_id] = "not_found"
            continue
        # The duration the server knows wins over the browser's.
        duration = durations[video_id] or entry.duration_seconds
        position = min(entry.position_seconds, duration or MAX_MEDIA_SECONDS)
        observed[video_id] = min(entry.watched_at, now)
        rows.append({
            "user_id": user.id,
            "video_id": video_id,
            "position_seconds": position,
            "duration_seconds": duration,
            "completed": is_completed(position, duration),
            "first_watched_at": now,
            "last_watched_at": observed[video_id],
            "updated_at": now,
        })

    stored: dict[UUID, WatchHistory] = {}
    if rows:
        db.execute(upsert_statement(db.get_bind().dialect.name, rows))
        db.commit()
        stored = _rows_for(db, user.id, observed)

    out = []
    for video_id in latest:
        result = results.get(video_id)
        row = stored.get(video_id)
        if result is None:
            # Ours if the stored observation is the one we sent.
            result = "saved" if row is not None and utc(row.last_watched_at) == observed[video_id] else "stale"
        out.append(ProgressResult(
            video_id=video_id,
            result=result,
            progress=_progress(row) if row is not None and result in ("saved", "stale") else None,
        ))
    return RecordProgressResponse(results=out)


@router.get("/positions", response_model=PositionsResponse)
def get_positions(
    video_ids: Annotated[str, Query(min_length=1, max_length=MAX_IDS * 37)],
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """The caller's progress on up to 50 videos (comma-separated ids). A
    video with no entry is left out. Reads only the caller's rows, so it
    needs no visibility check."""
    try:
        ids = list(dict.fromkeys(UUID(part.strip()) for part in video_ids.split(",")))
    except ValueError:
        raise APIError(400, "validation_error", "video_ids must be comma-separated UUIDs") from None
    if not 1 <= len(ids) <= MAX_IDS:
        raise APIError(400, "validation_error", f"video_ids takes 1 to {MAX_IDS} ids")
    rows = _rows_for(db, user.id, ids)
    return PositionsResponse(items=[_progress(rows[i]) for i in ids if i in rows])


@router.get("", response_model=HistoryResponse)
def list_history(
    limit: Annotated[int, Query(ge=1, le=50)] = 20,
    cursor: Annotated[str | None, Query(max_length=200)] = None,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """The caller's history, most recently watched first, keyset-paged. Only
    videos the caller can watch now are listed."""
    query = (
        select(WatchHistory)
        .join(WatchHistory.video)
        .options(contains_eager(WatchHistory.video).joinedload(Video.user))
        .where(WatchHistory.user_id == user.id, viewable_by(user.id))
        .order_by(WatchHistory.last_watched_at.desc(), WatchHistory.video_id.desc())
        .limit(limit + 1)
    )
    if cursor:
        when, video_id = decode_cursor(cursor)
        query = query.where(
            tuple_(WatchHistory.last_watched_at, WatchHistory.video_id) < (when, video_id)
        )
    rows = db.scalars(query).all()
    page, more = rows[:limit], len(rows) > limit
    return HistoryResponse(
        items=[HistoryItem(video=to_feed_item(r.video), progress=_progress(r)) for r in page],
        next_cursor=encode_cursor(page[-1].last_watched_at, page[-1].video_id) if more else None,
    )


@router.delete("", status_code=status.HTTP_204_NO_CONTENT)
def clear_history(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    db.execute(delete(WatchHistory).where(WatchHistory.user_id == user.id))
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete("/{video_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_from_history(
    video_id: UUID, user: User = Depends(get_current_user), db: Session = Depends(get_db),
):
    """Idempotent: 204 whether or not there was an entry."""
    db.execute(delete(WatchHistory).where(
        WatchHistory.user_id == user.id, WatchHistory.video_id == video_id,
    ))
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
