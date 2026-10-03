# Watch History — Implementation Plan

Signed-in users get a history of the videos they watched and resume each one
where they stopped, on any device. This plan covers the schema, the API, and
the Flutter changes, and gives the order to build them in.

It builds on the backend as it stands (`backend/app/`, migrations up to
`0002`) and the Flutter app on `feature/flutter-frontend` (`frontend/`).

---

## Contents

1. Goals and non-goals
2. Key decisions
3. Database schema
4. Sync rules (how devices agree)
5. API
6. Backend changes, file by file
7. Frontend changes
8. Testing
9. Rollout and milestones
10. Risks and open questions

---

## 1. Goals and non-goals

**Goals**

- Record every video a signed-in user watches, with the last position they
  reached.
- Resume a video at that position on any device signed in to the same account.
- A **History** screen: most recently watched first, with a progress bar on
  each card, *Remove from history*, and *Clear all history*.
- A red "watched" bar on feed and My Videos thumbnails, as on YouTube.
- Keep progress that was recorded offline or while the app was being killed,
  and sync it later without overwriting newer progress from another device.

**Non-goals for v1** (possible follow-ups, see §10)

- *Pause history*.
- Recommendations or "continue watching" rows built on the history.
- Per-view analytics (watch time, retention curves). `views_count` and
  `POST /video/{id}/view` are unchanged.
- History for signed-out viewers. The API requires sign-in, and the app
  already requires sign-in for everything.

---

## 2. Key decisions

| # | Decision | Why |
|---|---|---|
| H1 | One row per (user, video). Rewatching updates the row and moves it to the top. | Matches YouTube, where a video appears once in history. Keeps the table at most *users × videos watched*. |
| H2 | The client sends progress; the server stores the latest by **observation time** (`watched_at`), not by arrival time. | Offline progress flushed late must not overwrite newer progress from another device (§4). |
| H3 | The server clamps `watched_at` to `now()`. | A device whose clock runs fast can't pin its entry above everyone else's. |
| H4 | The server derives `completed` (≥ 95 % watched, or ≤ 10 s left). | One rule across all clients. A finished video restarts from 0 instead of resuming in the end credits. |
| H5 | One write endpoint takes a **batch** of 1–50 entries. Playback sends one; an offline flush sends many. | Every authenticated request costs a Cognito `GetUser` call (`app/deps.py`), so batching the flush saves calls. Also gives one code path. |
| H6 | Write cadence: every 15 s while playing, plus on pause, seek, finish, leaving the player, and the app going to the background. | Loses at most ~15 s if the app is killed. Keeps write load and `GetUser` calls bounded (§10). |
| H7 | History lists use a **keyset cursor**, not `page`/`offset`. | History reorders as you watch. With offsets, rewatching on another device while you scroll would duplicate or skip rows. |
| H8 | Rows for videos that became unwatchable (PRIVATE and not yours, or not COMPLETED) are **kept but hidden** on read. Deleting a video deletes its rows (FK `ON DELETE CASCADE`). | If the owner makes the video public again, it comes back to history. Nothing about a private video leaks. |
| H9 | Per-user progress is never put in the shared `video:meta` cache or in `GET /video/{id}`. Thumbnail bars use a separate lookup endpoint. | The cache is shared by all viewers (`app/cache.py`), and `/video/feed` takes no auth. |
| H10 | An entry is created only after **5 s of playback**. | Accidental taps don't fill the history. |

---

## 3. Database schema

### 3.1 New table `watch_history`

| Column | Type | Null | Notes |
|---|---|---|---|
| `user_id` | `uuid` | no | FK → `users.id` `ON DELETE CASCADE` |
| `video_id` | `uuid` | no | FK → `videos.id` `ON DELETE CASCADE` |
| `position_seconds` | `integer` | no | Last position reached, ≥ 0. Clamped to the duration. |
| `duration_seconds` | `integer` | yes | Duration the client's player reported. Used when `videos.duration_seconds` is null. |
| `completed` | `boolean` | no | Default `false`. Derived by the server (H4). |
| `first_watched_at` | `timestamptz` | no | Default `now()`. Set on insert only. |
| `last_watched_at` | `timestamptz` | no | Observation time of the stored progress (H2, H3). Drives ordering and conflict resolution. |
| `updated_at` | `timestamptz` | no | Server write time, for debugging and future incremental sync. |

**Constraints and indexes**

- `pk_watch_history` primary key `(user_id, video_id)`. Also serves the
  per-video lookups (`GET /history/positions`, the upsert).
- `ix_watch_history_user_id_last_watched` on
  `(user_id, last_watched_at DESC, video_id DESC)` for the history list and its
  keyset cursor.
- `ix_watch_history_video_id` on `(video_id)`, so the cascade on video delete
  doesn't scan the table.
- `ck_watch_history_position_nonneg`: `position_seconds >= 0`.

### 3.2 ORM model (`app/models.py`)

```python
class WatchHistory(Base):
    """One row per (user, video): the latest progress the user reached.
    Written only by the /history routes."""

    __tablename__ = "watch_history"
    __table_args__ = (
        Index(
            "ix_watch_history_user_id_last_watched",
            "user_id", text("last_watched_at DESC"), text("video_id DESC"),
        ),
        CheckConstraint("position_seconds >= 0", name="position_nonneg"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True,
    )
    video_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("videos.id", ondelete="CASCADE"), primary_key=True, index=True,
    )
    position_seconds: Mapped[int] = mapped_column(Integer)
    duration_seconds: Mapped[int | None] = mapped_column(Integer)
    completed: Mapped[bool] = mapped_column(Boolean, default=False, server_default=text("false"))
    first_watched_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(),
    )
    last_watched_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime] = _updated_at()

    video: Mapped[Video] = relationship()
```

`User` and `Video` don't need back-references. `passive_deletes` isn't
needed either, because nothing loads history through them.

### 3.3 Migration `0003_watch_history.py`

Additive only, like `0002`: one `create_table` plus the two extra indexes.
Tasks still running `0002` code keep working while the deploy rolls out.
`downgrade()` drops the table. Run `alembic check` afterwards to confirm the
model and the revision match.

### 3.4 Size

Each row is roughly 80 bytes plus about 60 bytes of index entries. One
million users × 200 videos each is about 28 GB, so v1 needs no retention
limit. A cap (for example, keep the latest 1,000 per user) is an open question
(§10).

---

## 4. Sync rules (how devices agree)

Every progress report carries the time it was **observed** on the device
(`watched_at`). The server keeps the report with the latest observation time:

```sql
INSERT INTO watch_history AS h
       (user_id, video_id, position_seconds, duration_seconds, completed,
        last_watched_at)
VALUES (:user_id, :video_id, :pos, :dur, :completed, LEAST(:watched_at, now()))
ON CONFLICT (user_id, video_id) DO UPDATE
   SET position_seconds = EXCLUDED.position_seconds,
       duration_seconds = COALESCE(EXCLUDED.duration_seconds, h.duration_seconds),
       completed        = EXCLUDED.completed,
       last_watched_at  = EXCLUDED.last_watched_at,
       updated_at       = now()
 WHERE h.last_watched_at <= EXCLUDED.last_watched_at
RETURNING h.video_id;          -- no row returned ⇒ the report was stale
```

What this gives you:

- **Phone, then tablet.** You watch to 4:10 on the phone and open the tablet.
  The tablet fetches the position and resumes at 4:10. It then reports newer
  observations, which win.
- **Offline phone flushes late.** The phone watched to 2:00 offline at 10:00,
  and the tablet then watched to 6:00 at 10:30. When the phone comes online at
  11:00 it sends `watched_at = 10:00`, which is older than the stored 10:30,
  so it is ignored (`stale`). The tablet's 6:00 stays.
- **Fast clock.** A device 10 minutes ahead sends a `watched_at` in the
  future. `LEAST(..., now())` turns it into the server's time, so it can't
  block other devices' reports for the next 10 minutes.
- **Slow clock.** A device that is behind looks older than it is, so it can
  lose a race against another device's real report. That is acceptable: the
  other device really was more recent, or close to it.
- **Rewinding.** Seeking backwards stores the earlier position. "Latest" means
  the most recent observation, not the furthest point reached. This matches
  YouTube and is what you expect to resume at.

**Derived fields** (server side, at write):

```
effective_duration = videos.duration_seconds or entry.duration_seconds
position = min(entry.position_seconds, effective_duration) if known else min(entry.position_seconds, 86_400)
completed = effective_duration is not None and
            (position >= 0.95 * effective_duration or effective_duration - position <= 10)
```

**Who may write:** the caller must be able to watch the video, as for
`GET /video/{id}`: the video is COMPLETED and either not PRIVATE or owned by
the caller. Any other entry comes back `not_found`, so a private video's
existence doesn't leak, and the client drops it from its outbox.

---

## 5. API

New router `app/routers/history.py`, prefix `/history`, tag `history`. Every
route requires sign-in (`Depends(get_current_user)`) and returns errors with
a `code` like the rest of the API.

### 5.1 `POST /history/progress` — record progress (batch)

Request:

```json
{
  "entries": [
    {
      "video_id": "8f1c…",
      "position_seconds": 254,
      "duration_seconds": 612,
      "watched_at": "2026-10-03T10:15:04.512Z"
    }
  ]
}
```

| Field | Rules |
|---|---|
| `entries` | 1–50 items. Duplicate `video_id`s are allowed; the one with the latest `watched_at` wins. |
| `position_seconds` | Integer, 0–86,400. |
| `duration_seconds` | Optional integer, 1–86,400. |
| `watched_at` | ISO-8601 **with a timezone offset**. Naive timestamps are a 400. Older than 30 days is a 400 for that batch (`validation_error`); the client drops such entries before sending. |

Response `200`:

```json
{
  "results": [
    {
      "video_id": "8f1c…",
      "result": "saved",
      "progress": {
        "video_id": "8f1c…",
        "position_seconds": 254,
        "duration_seconds": 612,
        "completed": false,
        "last_watched_at": "2026-10-03T10:15:04.512Z"
      }
    }
  ]
}
```

`result` is one of:

- `saved`: stored.
- `stale`: ignored, because the server has a newer observation. `progress`
  holds the server's current entry, so the client can adopt it.
- `not_found`: the video doesn't exist or the caller can't watch it.
  `progress` is null.

A batch never fails because one of its videos is bad: the results report each
entry. One statement per batch: load the viewable videos with
`WHERE id = ANY(:ids)`, then a single multi-row `INSERT … ON CONFLICT`.

### 5.2 `GET /history` — the history list

Query: `limit` (1–50, default 20) and `cursor` (opaque, optional).

Response `200`:

```json
{
  "items": [
    {
      "video": { "…every FeedItem field…": "…" },
      "progress": {
        "video_id": "8f1c…",
        "position_seconds": 254,
        "duration_seconds": 612,
        "completed": false,
        "last_watched_at": "2026-10-03T10:15:04.512Z"
      }
    }
  ],
  "next_cursor": "MjAyNi0xMC0wM1QxMDoxNTowNC41MTJafDhmMWMt…"
}
```

- Order: `last_watched_at DESC, video_id DESC`.
- Only videos the caller can watch now (H8). Hidden rows aren't counted.
  There is **no `total`**: it would need a second filtered count, and the
  screen doesn't show one.
- `next_cursor` is base64url of `"<last_watched_at ISO>|<video_id>"` for the
  last item, or null at the end. The next page uses
  `WHERE (last_watched_at, video_id) < (:ts, :id)`. A cursor that doesn't
  decode is `400 history_cursor_invalid`.
- The video fields come from the same `_feed_fields` helper as the feed, with
  `joinedload(Video.user)`. Move `_feed_fields` and `_to_feed_item` into a
  small module (`app/video_views.py`) so both routers share them.

### 5.3 `GET /history/positions` — progress for specific videos

Query: `video_ids`, comma-separated, 1–50 UUIDs.

Response `200`: `{ "items": [ <progress>, … ] }`, containing only the videos
that have an entry. A missing id means "never watched". The query runs on the
primary key and doesn't join `videos`: the caller is asking about ids they
already have, and only their own progress comes back.

Used by the player (one id, to resume) and by the feed and My Videos (one page
of ids, for the red bars).

### 5.4 `DELETE /history/{video_id}` — remove one entry

`204`, also when there was no entry (idempotent).

### 5.5 `DELETE /history` — clear all

`204`. Deletes every row for the caller in one statement.

### 5.6 Route order

Declare `/history/progress` and `/history/positions` before
`/history/{video_id}`, as `video.py` does for `/feed` and `/mine`. Only
`DELETE` uses the path parameter, so there's no clash today, but keeping the
order guards future `GET /history/{video_id}`.

### 5.7 Summary

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/history/progress` | cookie / Bearer | Record progress (batch of 1–50) |
| GET | `/history` | cookie / Bearer | The caller's history, newest first, keyset cursor |
| GET | `/history/positions` | cookie / Bearer | Progress for up to 50 given videos |
| DELETE | `/history/{video_id}` | cookie / Bearer | Remove one entry |
| DELETE | `/history` | cookie / Bearer | Clear all history |

---

## 6. Backend changes, file by file

| File | Change |
|---|---|
| `app/models.py` | `WatchHistory` model (§3.2). |
| `migrations/versions/0003_watch_history.py` | New table and indexes (§3.3). |
| `app/schemas.py` | `ProgressEntryIn`, `RecordProgressRequest`, `WatchProgress`, `ProgressResult`, `RecordProgressResponse`, `HistoryItem`, `HistoryResponse`, `PositionsResponse`. `watched_at` validator: reject naive datetimes, reject older than 30 days. |
| `app/video_views.py` (new) | `_feed_fields`, `_to_feed_item`, `_thumbnail_url`, `_manifest_url`, and a `viewable_by(user_id)` SQL expression (`status = COMPLETED AND (visibility != PRIVATE OR user_id = :me)`), moved out of `routers/video.py`. |
| `app/routers/history.py` (new) | The five routes (§5) and the upsert (§4). |
| `app/routers/video.py` | Import the moved helpers. No behaviour change. |
| `app/main.py` | `app.include_router(history.router)`. |
| `backend/AGENTS.md`, `backend/README.md`, `docs/api-and-db-schema-spec.md` | Route table, the new table, and the sync rules. |

The completion poller and the transcoder don't change. Deleting a video
already removes its history rows through the cascade, so `DELETE /video/{id}`
doesn't change either.

---

## 7. Frontend changes

### 7.1 New and changed files

```
lib/
├── models/
│   ├── watch_progress.dart          NEW  WatchProgress (+ fromJson, fraction, resumeAt)
│   └── history_entry.dart           NEW  HistoryEntry(video, progress)
├── services/
│   ├── history_service.dart         NEW  record(), list(cursor), positions(ids), remove(id), clear()
│   └── history_outbox.dart          NEW  persisted pending reports, keyed by user and video
├── core/
│   └── watch_progress_store.dart    NEW  in-memory videoId → WatchProgress, a ValueNotifier for the cards
├── playback/
│   └── progress_tracker.dart        NEW  BetterPlayer events → reports (heartbeat, pause, seek, exit)
├── cubits/history/
│   ├── history_cubit.dart           NEW  cursor paging, remove, clear
│   └── history_state.dart           NEW
├── pages/
│   ├── history_page.dart            NEW
│   ├── video_player_page.dart       CHANGED  resume + tracker
│   ├── home_page.dart               CHANGED  account menu → History; fetch positions per page
│   └── my_videos_page.dart          CHANGED  fetch positions per page
├── widgets/
│   ├── video_card.dart              CHANGED  optional watch-progress bar on the thumbnail
│   └── resume_chip.dart             NEW  "Resumed from 4:14 · Start over"
└── main.dart                        CHANGED  provide HistoryService/outbox/store; flush on resume & sign-in
```

### 7.2 Models

```dart
class WatchProgress {
  final String videoId;
  final int positionSeconds;
  final int? durationSeconds;
  final bool completed;
  final DateTime lastWatchedAt;

  /// 0–1 for the thumbnail bar; completed shows a full bar.
  double get fraction;

  /// Where to start playing, or null to start from the beginning:
  /// null if completed or under 5 s; otherwise position − 2 s,
  /// so the viewer sees a moment of context again.
  Duration? get resumeAt;
}
```

`HistoryEntry` pairs a `Video` (parsed by the existing `Video.fromJson`) with
its `WatchProgress`.

### 7.3 Recording progress: `ProgressTracker` and `HistoryOutbox`

**`ProgressTracker`** is created by `VideoPlayerPage` alongside the
`BetterPlayerController`, and listens to the same events:

| Event | Action |
|---|---|
| `progress` | Remember `position` and `duration`. Add the time since the last tick to played time (only while playing, and only if the jump is < 2 s, so seeks don't count). |
| `play` | Start a 15 s heartbeat timer. |
| `pause`, `finished` | Report now; stop the timer. |
| `seekTo` | Report after the seek settles (debounced 1 s). |
| page `dispose`, `AppLifecycleState.paused` / `hidden` | Report now (send best-effort; it's already in the outbox). |

Nothing is reported until 5 s have been played (H10). After that, each report
is `{videoId, position, duration, watchedAt: DateTime.now().toUtc()}`.

Reports go into **`HistoryOutbox`**, never straight to the network:

- Stored as JSON in `<app support>/history_outbox_<userId>.json` (same pattern
  as `UploadJobStore`). Keyed by video, so it holds at most one report per
  video, the newest by `watchedAt`.
- `flush()` sends up to 50 at a time to `POST /history/progress`, then
  removes the ones the server answered `saved`, `stale`, or `not_found`. A
  network error or 5xx keeps them for the next flush. A `401` is handled by
  the existing refresh interceptor.
- Flushes run after each report (debounced 2 s), when the app resumes, after
  sign-in and session restore, and every 60 s while the outbox isn't empty.
- Before logout: one flush, with a 3 s timeout, then delete the outbox file.
  The file name contains the user id, so another account on the same phone
  never sends this user's progress.
- Drop entries older than 30 days without sending (the server would reject
  them).

When a report is written, the tracker also updates `WatchProgressStore`, so
the feed card shows the new bar as soon as you go back, without a refetch.

### 7.4 Resume in `VideoPlayerPage`

1. When the page opens, fetch the position in parallel with
   `VideoDetailCubit.load`: `HistoryService.positions([id])`. Skip the fetch
   when the caller already passed a fresh `WatchProgress` (from the History
   page or the store).
2. Use the **newer** of the server answer and any pending report for this
   video in the outbox (an offline watch on this device beats an older server
   value).
3. Build the player with `BetterPlayerConfiguration(startAt: resumeAt)`.
   (`startAt` exists in `better_player_plus`; the controller seeks there
   after initialisation.)
4. Don't hold playback for the lookup longer than 1.5 s. If it hasn't
   answered by then, start from 0 and ignore the late answer. Seeking under
   the viewer's hands is worse than not resuming.
5. When the video resumed, show `ResumeChip` over the player for 4 s:
   "Resumed from 4:14 · **Start over**". *Start over* calls `seekTo(0)`.

### 7.5 History page

- Opened from **Account menu → History** on Home (between *My videos* and
  *Log out*).
- `HistoryCubit` follows `FeedCubit`'s shape, but pages by `next_cursor`
  instead of `page`. It has `load`, `refresh`, `loadMore`, `remove(id)`
  (optimistic, restored on error), and `clear()`.
- Rows grouped under date headers: *Today*, *Yesterday*, *This week*, then
  month names. The groups are computed in the cubit from `lastWatchedAt` in
  local time.
- Each row is a `VideoCard` with the progress bar, and the meta line shows
  "Watched 2 h ago". The ⋮ menu has *Remove from history*, and swiping left
  removes too, with an *Undo* snackbar. Undo re-sends the last known progress
  with its original `watchedAt`, so it is restored exactly.
- App bar ⋮ → *Clear all watch history* asks for confirmation, then calls
  `DELETE /history`, empties the list and the `WatchProgressStore`, and
  clears this user's outbox. Otherwise a pending report would add an entry
  straight back.
- Empty state: "Videos you watch will show up here." Errors use
  `ErrorView.fromException` with *Retry*.
- Tapping a row opens the player with the entry's `WatchProgress`, so the
  player skips the lookup. When you come back, the list is refreshed, because
  the video you just watched moves to the top.

### 7.6 Progress bars on feed and My Videos

- After each page loads, `HomePage` and `MyVideosPage` call
  `positions(pageIds)` (one request per page of ≤ 50) and merge the answer
  into `WatchProgressStore`. A failure is ignored: the bars are decoration.
- `VideoCard` gets `WatchProgress? watched`. When it's set, a 3 px red
  (`YtColors.red`) bar is drawn along the bottom of the thumbnail, over a
  translucent grey track, at `fraction`. Semantics adds "watched 41 %".
- Cards listen to the store with a `ValueListenableBuilder` keyed by video id,
  so a bar updates when you come back from the player.

### 7.7 Wiring (`main.dart`)

- Provide `HistoryService` (on the `api` Dio), `HistoryOutbox`, and
  `WatchProgressStore` next to `VideoService`.
- When `SessionCubit` becomes authenticated: open the outbox for that user id
  and flush it.
- When it becomes unauthenticated: flush (as above), close the outbox, and
  clear the store.
- An `AppLifecycleListener` at the root flushes on `resumed`.

### 7.8 Older backends

If `POST /history/progress` answers `404` with code `not_found` (a backend
without this feature), the tracker turns itself off for the session and keeps
the outbox, and the History menu item shows "Not available on this server".
This keeps the app usable against a backend that hasn't been deployed yet,
which matters with the in-app server URL in dev builds.

---

## 8. Testing

### 8.1 Backend

The backend has no automated tests yet. Add `pytest` with a throwaway
PostgreSQL (the `docker compose` `postgres` service, or `testcontainers`) and
a stubbed `get_current_user`. The first suite covers this feature:

- Upsert: first report inserts; a newer one updates; an older one is `stale`
  and returns the stored entry; equal `watched_at` overwrites (idempotent
  retry).
- A future `watched_at` is clamped to `now()`.
- A naive timestamp, or one older than 30 days, is a 400; 51 entries is a 400.
- Duplicate ids in one batch: the latest wins.
- `completed` at 94 %, 95 %, 10 s left, and with a null duration.
- Position over the duration is clamped.
- `not_found` for: a missing video, someone else's PRIVATE video, PENDING,
  FAILED. The owner's own PRIVATE video is `saved`.
- `GET /history`: order; the cursor walks every row exactly once while
  another "device" reports in between; hidden rows (made PRIVATE) disappear,
  then reappear when made PUBLIC again; a bad cursor gives
  `history_cursor_invalid`.
- `GET /history/positions`: only own rows; 51 ids is a 400; malformed UUIDs
  are a 400.
- `DELETE` one entry, and clear all; deleting a video cascades its rows.
- Every route without a token is a 401 `missing_access_token`.
- `alembic upgrade head`, then `alembic check`, both pass.

### 8.2 Frontend

Using the existing setup (mocktail, bloc_test, http_mock_adapter):

- `WatchProgress`: `fraction`, `resumeAt` (completed, under 5 s, normal).
- `HistoryService`: request shapes, parsing the three `result` values,
  cursor passthrough.
- `HistoryOutbox`: keeps only the newest per video; survives a reload from
  disk; removes `saved`/`stale`/`not_found` after a flush and keeps entries
  after a network error; batches of 50; drops entries > 30 days; separate
  files per user.
- `ProgressTracker` (fake clock and fake events): nothing before 5 s;
  heartbeat every 15 s; reports on pause, seek (debounced), finish, and
  dispose; seeks don't count as played time.
- `HistoryCubit`: paging by cursor, optimistic remove and restore on error,
  clear, date grouping across midnight.
- Widget tests: the History page (list, empty, error, swipe + undo, clear
  confirmation); the bar on `VideoCard`; `ResumeChip` and *Start over*.
- Extend `integration_test/app_test.dart`: play a video for 10 s, leave,
  open History, see the entry; reopen and check the player starts near 10 s.

### 8.3 Manual cross-device check

Two devices on one account: watch to 2:00 on A → open on B, it resumes at
about 1:58. Put A in airplane mode, watch to 3:00, then watch to 5:00 on B,
then bring A back online → B's 5:00 stays. Remove an entry on A → it's gone on
B after a refresh. Clear all on B → A's History is empty after a refresh.

---

## 9. Rollout and milestones

The backend ships first. It's additive, so the current app is unaffected.

| Step | Scope | Done when |
|---|---|---|
| **W1** Schema | Model, migration `0003`, `video_views.py` refactor | `alembic upgrade head` and `alembic check` pass on a fresh DB and on a copy of the current one |
| **W2** API | `routers/history.py`, schemas, docs, pytest suite | §8.1 green; endpoints exercised via `/docs` |
| **W3** Recording + resume | Models, `HistoryService`, `HistoryOutbox`, `ProgressTracker`, `WatchProgressStore`, player changes, lifecycle flushes | Unit tests green; manual: resume works across two devices |
| **W4** History screen | `HistoryCubit`, `HistoryPage`, account-menu entry, remove/undo/clear | Widget tests green |
| **W5** Thumbnail bars | Positions fetch in Home and My Videos; `VideoCard` bar | Widget test green; bars update after leaving the player |
| **W6** Hardening | Older-backend fallback (§7.8), integration test, cross-device check (§8.3), metrics on the write rate | Checklist done |

W1 and W2 deploy on their own. W3–W5 can each be a separate PR into the app.

---

## 10. Risks and open questions

### Risks

- **Cognito `GetUser` per write.** Every authenticated request calls Cognito
  (`app/deps.py`). 1,000 concurrent viewers × 1 write / 15 s ≈ 67 `GetUser`
  calls/s, on top of normal traffic, and Cognito's API quotas are per account.
  Mitigations here: the 15 s cadence, and batching offline flushes (H5). The
  real fix is to verify the access-token JWT locally against the pool's JWKS
  and only call `GetUser` when needed. That change is worth doing for the
  whole API, separately from this feature.
- **Write load on PostgreSQL.** The same 1,000 viewers make about 67 upserts/s
  on a narrow table, which is fine for RDS. If it grows by orders of
  magnitude, buffer reports in Redis and have a worker flush them every few
  seconds. The API contract wouldn't change.
- **Reports lost on a kill.** iOS and Android can kill the app without a
  lifecycle callback. At most one heartbeat (≤ 15 s) is lost, because every
  report is written to the outbox file before it's sent.
- **Clock skew.** Covered by H3 and §4. A device with a slow clock can lose a
  race to another device it was actually concurrent with. Accepted.
- **`better_player_plus` event details.** `progress` events are throttled
  inside the package (about every 500 ms), and fullscreen opens a new route.
  Check during W3 that the tracker keeps receiving events in fullscreen and
  in picture-in-picture.

### Open questions

1. **Retention:** keep everything, or cap at the newest N per user (for
   example 1,000) with a nightly prune?
2. **Pause history:** add a `users.history_paused` flag that makes
   `POST /history/progress` a no-op? It's cheap to add later; it's not in v1.
3. **Own videos:** record history when an owner watches their own upload?
   This plan says yes, like YouTube.
4. **Completion threshold:** is 95 % / 10 s right for short videos? For a
   20 s clip, the 10 s rule marks it complete at the halfway point. A
   minimum-duration condition may be needed.
5. **Unavailable videos in history:** hide them (this plan), or show a grey
   "This video is unavailable" row as YouTube does?
6. **Search in history:** YouTube has it. It would need a title filter on
   `GET /history`. Not in v1.
