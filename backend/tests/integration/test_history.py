"""Watch history against the seeded SQLite rows (seed_data.HISTORY).

The server keeps one database for the whole run, so the tests that read
Alice's seeded history come first, and the ones that write as Alice come
last. Everything else writes as Bob, who starts with no history.
"""

import base64
import uuid
from datetime import datetime, timedelta, timezone

import pytest

from tests.support import seed_data

V = seed_data.VIDEOS_BY_KEY


def _at(seconds: float = 0) -> datetime:
    return datetime.now(timezone.utc) + timedelta(seconds=seconds)


def _iso(when: datetime) -> str:
    return when.isoformat().replace("+00:00", "Z")


def _entry(key: str, position: int, when: datetime, duration: int | None = None) -> dict:
    e = {"video_id": str(V[key].id), "position_seconds": position, "watched_at": _iso(when)}
    if duration is not None:
        e["duration_seconds"] = duration
    return e


def _record(client, *entries: dict) -> list[dict]:
    r = client.post("/history/progress", json={"entries": list(entries)})
    assert r.status_code == 200, r.text
    return r.json()["results"]


def _ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _history_ids(client, **params) -> list[str]:
    body = client.get("/history", params={"limit": 50, **params}).json()
    return [i["video"]["id"] for i in body["items"]]


def _position(client, key: str) -> dict | None:
    items = client.get("/history/positions", params={"video_ids": str(V[key].id)}).json()["items"]
    return items[0] if items else None


# ---------- Auth ----------
@pytest.mark.parametrize("method, path", [
    ("POST", "/history/progress"),
    ("GET", "/history"),
    ("GET", f"/history/positions?video_ids={uuid.uuid4()}"),
    ("DELETE", "/history"),
    ("DELETE", f"/history/{uuid.uuid4()}"),
])
def test_every_route_needs_sign_in(anon, method, path):
    body = {"entries": [_entry("guitar", 1, _at())]} if method == "POST" else None
    r = anon.request(method, path, json=body)
    assert (r.status_code, r.json()["code"]) == (401, "missing_access_token")


# ---------- Reads of the seeded history (before anything writes as Alice) ----------
def test_seeded_history_newest_first(alice, bob):
    body = alice.get("/history").json()
    assert [i["video"]["id"] for i in body["items"]] == [str(V[h.video].id) for h in seed_data.ALICE_HISTORY]
    assert body["next_cursor"] is None

    first = body["items"][0]
    assert first["video"]["title"] == V["mountains"].title
    assert first["video"]["creator"] == {"id": str(seed_data.ALICE.id), "name": seed_data.ALICE.name}
    assert first["video"]["hls_url"].endswith("/master.m3u8")
    assert first["progress"] == {
        "video_id": str(V["mountains"].id),
        "position_seconds": 300,
        "duration_seconds": 615,
        "completed": False,
        "last_watched_at": "2025-12-31T23:00:00Z",
    }
    completed = {i["video"]["id"]: i["progress"]["completed"] for i in body["items"]}
    assert completed[str(V["guitar"].id)] is True
    assert completed[str(V["timelapse"].id)] is False

    assert bob.get("/history").json() == {"items": [], "next_cursor": None}


def test_paging_walks_every_row_once_while_others_write(alice, bob):
    page1 = alice.get("/history", params={"limit": 2}).json()
    assert len(page1["items"]) == 2 and page1["next_cursor"]
    # Another user's writes between pages don't move Alice's rows.
    _record(bob, _entry("guitar", 30, _at()))
    page2 = alice.get("/history", params={"limit": 2, "cursor": page1["next_cursor"]}).json()
    assert page2["next_cursor"] is None
    seen = [i["video"]["id"] for i in page1["items"] + page2["items"]]
    assert seen == [str(V[h.video].id) for h in seed_data.ALICE_HISTORY]


@pytest.mark.parametrize("cursor", [
    "!!!",
    base64.urlsafe_b64encode(b"not|a-cursor").decode(),
    base64.urlsafe_b64encode(f"2026-01-01T00:00:00|{uuid.uuid4()}".encode()).decode(),  # no offset
    base64.urlsafe_b64encode(b"\xff\xfe").decode(),
])
def test_bad_cursor(alice, cursor):
    r = alice.get("/history", params={"cursor": cursor})
    assert (r.status_code, r.json()["code"]) == (400, "history_cursor_invalid")


def test_positions_only_for_the_callers_watched_videos(alice, bob):
    ids = ",".join(str(V[k].id) for k in ("guitar", "cooking", "mountains"))
    items = alice.get("/history/positions", params={"video_ids": ids}).json()["items"]
    assert [i["video_id"] for i in items] == [str(V["guitar"].id), str(V["mountains"].id)]
    assert bob.get("/history/positions", params={"video_ids": str(V["mountains"].id)}).json() == {"items": []}

    too_many = ",".join(str(uuid.uuid4()) for _ in range(51))
    for bad in (too_many, "not-a-uuid", f"{V['guitar'].id},,"):
        r = alice.get("/history/positions", params={"video_ids": bad})
        assert (r.status_code, r.json()["code"]) == (400, "validation_error"), bad
    assert alice.get("/history/positions").status_code == 400


# ---------- Writes (as Bob) ----------
def test_latest_observation_wins(bob):
    t0, t1 = _at(-60), _at(-30)
    [r] = _record(bob, _entry("cooking", 100, t0))
    assert r["result"] == "saved"
    assert _ts(r["progress"]["last_watched_at"]) == t0
    assert r["progress"]["position_seconds"] == 100

    assert _record(bob, _entry("cooking", 200, t1))[0]["result"] == "saved"

    # Flushed late: observed before the stored report, so ignored, and the
    # answer carries the server's entry for the client to adopt.
    [late] = _record(bob, _entry("cooking", 150, _at(-50)))
    assert late["result"] == "stale"
    assert late["progress"]["position_seconds"] == 200
    assert _ts(late["progress"]["last_watched_at"]) == t1

    # A retry (same watched_at) overwrites itself.
    assert _record(bob, _entry("cooking", 200, t1))[0]["result"] == "saved"
    assert _position(bob, "cooking")["position_seconds"] == 200
    assert str(V["cooking"].id) in _history_ids(bob)


def test_future_watched_at_is_clamped_to_the_server_clock(bob):
    [r] = _record(bob, _entry("timelapse", 5, _at(600)))
    assert r["result"] == "saved"
    stored = _ts(r["progress"]["last_watched_at"])
    assert stored <= _at(5)
    # So a real report right after it still wins.
    assert _record(bob, _entry("timelapse", 9, _at(1)))[0]["result"] == "saved"
    assert _position(bob, "timelapse")["position_seconds"] == 9


@pytest.mark.parametrize("body", [
    {"entries": []},
    {"entries": [_entry("guitar", 1, _at())] * 51},
    {"entries": [{**_entry("guitar", 1, _at()), "watched_at": "2026-10-03T10:15:04"}]},  # naive
    {"entries": [_entry("guitar", -1, _at())]},
    {"entries": [_entry("guitar", 86_401, _at())]},
    {"entries": [_entry("guitar", 1, _at(), duration=0)]},
    {"entries": [{**_entry("guitar", 1, _at()), "video_id": "nope"}]},
    {},
])
def test_invalid_batches(bob, body):
    r = bob.post("/history/progress", json=body)
    assert (r.status_code, r.json()["code"]) == (400, "validation_error")


def test_an_old_report_is_expired_without_failing_the_batch(bob):
    results = _record(
        bob,
        _entry("cooking", 10, _at(-31 * 86_400)),
        _entry("mountains", 20, _at()),
    )
    assert [(r["video_id"], r["result"]) for r in results] == [
        (str(V["cooking"].id), "expired"), (str(V["mountains"].id), "saved"),
    ]
    assert results[0]["progress"] is None


def test_duplicate_ids_in_a_batch_keep_the_latest(bob):
    # drafts: a video Bob hasn't reported yet, so nothing stored is newer.
    results = _record(
        bob,
        _entry("drafts", 30, _at(-3)),
        _entry("drafts", 50, _at(-1)),
        _entry("drafts", 40, _at(-2)),
    )
    assert len(results) == 1
    assert (results[0]["result"], results[0]["progress"]["position_seconds"]) == ("saved", 50)


@pytest.mark.parametrize("position, completed", [
    (1720, False),  # 94 %
    (1738, False),  # just under 95 % (1738.5)
    (1739, True),   # 95 %
])
def test_completion_rule(bob, position, completed):
    # guitar is 1830 s long on the server.
    [r] = _record(bob, _entry("guitar", position, _at()))
    assert (r["progress"]["completed"], r["progress"]["duration_seconds"]) == (completed, 1830)


def test_short_video_completion_and_clamping(bob):
    # timelapse is 45 s: 10 s left means complete from 35 s.
    assert _record(bob, _entry("timelapse", 34, _at()))[0]["progress"]["completed"] is False
    assert _record(bob, _entry("timelapse", 35, _at()))[0]["progress"]["completed"] is True
    # A position past the end is clamped to the duration; the server's
    # duration wins over the browser's.
    [r] = _record(bob, _entry("timelapse", 900, _at(), duration=1000))
    assert (r["progress"]["position_seconds"], r["progress"]["duration_seconds"]) == (45, 45)


def test_videos_the_caller_cannot_watch_are_not_found(bob):
    results = _record(
        bob,
        {**_entry("guitar", 1, _at()), "video_id": str(uuid.uuid4())},
        _entry("diary", 10, _at()),       # Alice's PRIVATE video
        _entry("rendering", 10, _at()),   # PROCESSING
        _entry("broken", 10, _at()),      # FAILED (Bob's own)
        _entry("drafts", 10, _at()),      # UNLISTED: anyone with the link may watch
    )
    assert [r["result"] for r in results] == ["not_found"] * 4 + ["saved"]
    assert all(r["progress"] is None for r in results[:4])
    assert _position(bob, "diary") is None


def test_hidden_while_private_then_back(alice, bob):
    _record(bob, _entry("mountains", 60, _at()))
    assert str(V["mountains"].id) in _history_ids(bob)
    path = f"/video/{V['mountains'].id}"
    try:
        assert alice.patch(path, json={"visibility": "PRIVATE"}).status_code == 200
        assert str(V["mountains"].id) not in _history_ids(bob)
        # Reporting it now is not_found, and the kept row is untouched.
        assert _record(bob, _entry("mountains", 99, _at()))[0]["result"] == "not_found"
    finally:
        assert alice.patch(path, json={"visibility": "PUBLIC"}).status_code == 200
    assert _history_ids(bob)[0] == str(V["mountains"].id)
    assert _position(bob, "mountains")["position_seconds"] == 60


def test_remove_one_and_clear_all(bob):
    _record(bob, _entry("guitar", 10, _at(-2)), _entry("cooking", 10, _at(-1)))
    path = f"/history/{V['guitar'].id}"
    assert bob.delete(path).status_code == 204
    assert bob.delete(path).status_code == 204  # idempotent
    assert bob.delete(f"/history/{uuid.uuid4()}").status_code == 204
    assert str(V["guitar"].id) not in _history_ids(bob)
    assert str(V["cooking"].id) in _history_ids(bob)

    assert bob.delete("/history").status_code == 204
    assert bob.get("/history").json()["items"] == []
    assert bob.get("/history/positions", params={"video_ids": str(V["cooking"].id)}).json() == {"items": []}


# ---------- Writes as Alice (last: they reorder her seeded history) ----------
def test_owner_records_their_own_private_video(alice):
    [r] = _record(alice, _entry("diary", 70, _at()))
    assert r["result"] == "saved"
    assert _history_ids(alice)[0] == str(V["diary"].id)


def test_clearing_is_per_user(alice, bob):
    _record(bob, _entry("guitar", 10, _at()))
    assert bob.delete("/history").status_code == 204
    assert len(_history_ids(alice)) == len(seed_data.ALICE_HISTORY)
