"""Watch history: the pure helpers, the upsert on both dialects, and the
cascade from DELETE /video/{id}, in-process on SQLite."""

import sqlite3
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from pydantic import ValidationError
from sqlalchemy.dialects import postgresql, sqlite

from app.errors import APIError
from app.schemas import ProgressEntryIn
from app.watch_progress import (
    decode_cursor, encode_cursor, is_completed, latest_per_video, upsert_statement, utc,
)
from tests.support import seed_data


def test_cursor_round_trip():
    when = datetime(2026, 10, 3, 10, 15, 4, 512_000, tzinfo=timezone.utc)
    vid = uuid.uuid4()
    cursor = encode_cursor(when, vid)
    assert "=" not in cursor and "+" not in cursor and "/" not in cursor
    assert decode_cursor(cursor) == (when, vid)
    # SQLite hands back naive UTC; the cursor is the same.
    assert encode_cursor(when.replace(tzinfo=None), vid) == cursor


@pytest.mark.parametrize("cursor", ["", "@@", "eA", "MjAyNnxub3BlCg"])
def test_bad_cursor_is_an_api_error(cursor):
    with pytest.raises(APIError) as err:
        decode_cursor(cursor)
    assert (err.value.status_code, err.value.code) == (400, "history_cursor_invalid")


def testutc():
    naive = datetime(2026, 1, 1, 12)
    assert utc(naive) == naive.replace(tzinfo=timezone.utc)
    ist = datetime(2026, 1, 1, 17, 30, tzinfo=timezone(timedelta(hours=5, minutes=30)))
    assert utc(ist) == datetime(2026, 1, 1, 12, tzinfo=timezone.utc)
    assert utc(ist).tzinfo is timezone.utc


@pytest.mark.parametrize("position, duration, expected", [
    (0, None, False),
    (10_000, None, False),
    (569, 600, False),
    (570, 600, True),    # 95 %
    (30, 40, True),      # 10 s left
    (29, 40, False),
    (600, 600, True),
])
def test_completion_rule(position, duration, expected):
    assert is_completed(position, duration) is expected


def test_entry_needs_an_offset_and_is_stored_inutc():
    vid = uuid.uuid4()
    with pytest.raises(ValidationError):
        ProgressEntryIn(video_id=vid, position_seconds=1, watched_at="2026-10-03T10:15:04")
    e = ProgressEntryIn(video_id=vid, position_seconds=1, watched_at="2026-10-03T15:45:04+05:30")
    assert e.watched_at == datetime(2026, 10, 3, 10, 15, 4, tzinfo=timezone.utc)
    assert e.watched_at.utcoffset() == timedelta(0)


def test_duplicates_keep_the_latest_in_first_seen_order():
    a, b = uuid.uuid4(), uuid.uuid4()
    t = datetime(2026, 10, 3, tzinfo=timezone.utc)

    def entry(vid, pos, minutes):
        return ProgressEntryIn(video_id=vid, position_seconds=pos, watched_at=t + timedelta(minutes=minutes))

    latest = latest_per_video([entry(a, 1, 0), entry(b, 2, 5), entry(a, 3, 9), entry(a, 4, 1)])
    assert list(latest) == [a, b]
    assert latest[a].position_seconds == 3


@pytest.mark.parametrize("dialect", [postgresql.dialect(), sqlite.dialect()])
def test_upsert_builds_for_both_dialects(dialect):
    now = datetime.now(timezone.utc)
    row = {
        "user_id": uuid.uuid4(), "video_id": uuid.uuid4(), "position_seconds": 1,
        "duration_seconds": None, "completed": False, "first_watched_at": now,
        "last_watched_at": now, "updated_at": now,
    }
    sql = str(upsert_statement(dialect.name, [row, {**row, "video_id": uuid.uuid4()}]).compile(dialect=dialect))
    assert "ON CONFLICT (user_id, video_id) DO UPDATE" in sql
    assert "WHERE watch_history.last_watched_at <= excluded.last_watched_at" in sql
    # first_watched_at is set on insert only.
    assert "first_watched_at = " not in sql


# ---------- In-process ----------
def _login(client, user):
    r = client.post("/auth/login", json={"email": user.email, "password": seed_data.PASSWORD})
    assert r.status_code == 200


def _rows(client, video_id) -> int:
    with sqlite3.connect(client.db_path) as db:
        return db.execute(
            "SELECT count(*) FROM watch_history WHERE video_id = ?", (video_id.hex,),
        ).fetchone()[0]


def test_seeded_history_is_in_the_database(client):
    with sqlite3.connect(client.db_path) as db:
        assert db.execute("SELECT count(*) FROM watch_history").fetchone()[0] == len(seed_data.HISTORY)


def test_deleting_a_video_deletes_its_history(client):
    cooking = seed_data.VIDEOS_BY_KEY["cooking"]
    _login(client, seed_data.BOB)
    now = datetime.now(timezone.utc).isoformat()
    r = client.post("/history/progress", json={"entries": [
        {"video_id": str(cooking.id), "position_seconds": 5, "watched_at": now},
    ]})
    assert r.json()["results"][0]["result"] == "saved"
    assert _rows(client, cooking.id) == 1

    _login(client, seed_data.ALICE)
    assert client.delete(f"/video/{cooking.id}").status_code == 204
    assert _rows(client, cooking.id) == 0


def test_deleting_a_user_deletes_their_history(client):
    alice = seed_data.ALICE
    with sqlite3.connect(client.db_path) as db:
        db.execute("PRAGMA foreign_keys=ON")
        db.execute("DELETE FROM users WHERE id = ?", (alice.id.hex,))
        left = db.execute(
            "SELECT count(*) FROM watch_history WHERE user_id = ?", (alice.id.hex,),
        ).fetchone()[0]
    assert left == 0
