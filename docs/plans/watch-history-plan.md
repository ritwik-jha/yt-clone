# Watch History — Implementation Plan

Signed-in users get a history of the videos they watched and resume each one
where they stopped, in any browser where they're signed in. This plan covers
the schema, the API, and the changes to the web app, and gives the order to
build them in.

It builds on what is on `main` today:

- the backend in `backend/app/`, with migrations up to `0002` and the SQLite
  test harness in `backend/tests/`;
- the Flutter **web** app in `frontend/` (go_router, cookie session,
  `PlayerController` over hls.js / dash.js, the Figma look);
- the ECS deployment, where the app's nginx proxies API paths to the backend
  on the same origin (`frontend/deploy/nginx.conf.template`).

An earlier version of this plan targeted the Android/iOS app (BetterPlayer,
files in app storage, Bearer tokens). §11 lists what changed and why.

---

## Contents

1. Goals and non-goals
2. Key decisions
3. Database schema
4. Sync rules (how browsers agree)
5. API
6. Backend changes, file by file
7. Web app changes
8. Testing
9. Rollout and milestones
10. Risks and open questions
11. Changes from the mobile version of this plan

---

## 1. Goals and non-goals

**Goals**

- Record every video a signed-in user watches, with the last position they
  reached.
- Resume a video at that position in any browser signed in to the same
  account.
- A **History** page at `/feed/history`: most recently watched first, grouped
  by day, a progress bar on each thumbnail, *Remove from watch history* on
  each row, and *Clear all watch history*.
- A red "watched" bar along the bottom of every thumbnail the signed-in user
  has watched: the home grid, search results, channel pages, the watch page's
  up-next column, and Your videos.
- Keep progress recorded while the network was down, or in the moment the tab
  was closed, and sync it later without overwriting newer progress from
  another browser.

**Non-goals for v1** (possible follow-ups, see §10)

- *Pause history*.
- Recommendations or "continue watching" rows built on the history.
- Per-view analytics (watch time, retention curves). `views_count` and
  `POST /video/{id}/view` are unchanged.
- History for signed-out visitors. Browsing works signed out, but nothing is
  recorded and no bars are shown; `/feed/history` sends them to Sign in like
  Your videos does.
- Search within history.

---

## 2. Key decisions

| # | Decision | Why |
|---|---|---|
| H1 | One row per (user, video). Rewatching updates the row and moves it to the top. | Matches YouTube, where a video appears once in history. Keeps the table at most *users × videos watched*. |
| H2 | The client sends progress; the server stores the latest by **observation time** (`watched_at`), not by arrival time. | Progress flushed late (after a network drop, or on the next visit) must not overwrite newer progress from another browser (§4). |
| H3 | The server clamps `watched_at` to its own clock. | A machine whose clock runs fast can't pin its entry above everyone else's. |
| H4 | The server derives `completed` (≥ 95 % watched, or ≤ 10 s left). | One rule for every client. A finished video restarts from 0 instead of resuming in the end credits. |
| H5 | One write endpoint takes a **batch** of 1–50 entries. Playback sends one; a flush of the outbox sends many. | Every authenticated request costs a Cognito `GetUser` call (`app/deps.py`), so batching saves calls. Also one code path. |
| H6 | Write cadence: every 15 s while playing, plus on pause, seek, end, leaving the watch page, and the tab being hidden or closed. | Loses at most ~15 s if the browser crashes. Keeps write load and `GetUser` calls bounded (§10). |
| H7 | History lists use a **keyset cursor**, not `page`/`offset`. | History reorders as you watch. With offsets, watching in another tab while you scroll would duplicate or skip rows. |
| H8 | Rows for videos that became unwatchable (PRIVATE and not yours, or not COMPLETED) are **kept but hidden** on read. Deleting a video deletes its rows (FK `ON DELETE CASCADE`). | If the owner makes the video public again, it comes back to history. Nothing about a private video leaks. |
| H9 | Per-user progress is never put in the shared `video:meta` cache or in `GET /video/{id}`. Thumbnail bars use a separate lookup endpoint. | The cache is shared by every viewer (`app/cache.py`), and the feed, search, channel, and detail reads take no auth. |
| H10 | An entry is created only after **5 s of playback**. | Accidental clicks and up-next autoplay previews don't fill the history. |
| H11 | Unsent reports wait in a per-user **outbox in `localStorage`**, one key per video, written before any network call. | Writing `localStorage` is synchronous, so a report survives the tab closing mid-request. One key per video lets several tabs write without overwriting each other's reports. |
| H12 | Every query runs on PostgreSQL **and SQLite**: the upsert is built per dialect, `now()` is taken in Python, timestamps are stored in UTC. | The backend tests and the browser E2E run on SQLite (`backend/tests/support/server.py`); production runs on PostgreSQL. |

---

## 3. Database schema

### 3.1 New table `watch_history`

| Column | Type | Null | Notes |
|---|---|---|---|
| `user_id` | `uuid` | no | FK → `users.id` `ON DELETE CASCADE` |
| `video_id` | `uuid` | no | FK → `videos.id` `ON DELETE CASCADE` |
| `position_seconds` | `integer` | no | Last position reached, ≥ 0. Clamped to the duration. |
| `duration_seconds` | `integer` | yes | Duration the browser's `<video>` reported. Used when `videos.duration_seconds` is null. |
| `completed` | `boolean` | no | Default `false`. Derived by the server (H4). |
| `first_watched_at` | `timestamptz` | no | Default `now()`. Set on insert only. |
| `last_watched_at` | `timestamptz` | no | Observation time of the stored progress (H2, H3), UTC. Drives ordering and conflict resolution. |
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

`scripts/seed_sqlite.py` builds the test schema from these models with
`Base.metadata.create_all`, so the new table reaches the SQLite tests with no
extra step. SQLite keeps no time zone in a `DateTime` column, so the routes
convert every timestamp to UTC before writing and treat a naive value read
back as UTC (`_utc()` in §6).

### 3.3 Migration `0003_watch_history.py`

Additive only, like `0002`: one `create_table` plus the two extra indexes.
API tasks still running `0002` code keep working while the deploy rolls out
(each new task runs `alembic upgrade head` before it serves).
`downgrade()` drops the table. Run `alembic check` against the compose
PostgreSQL afterwards to confirm the model and the revision match.

### 3.4 Size

Each row is roughly 80 bytes plus about 60 bytes of index entries. One
million users × 200 videos each is about 28 GB, so v1 needs no retention
limit. A cap (for example, keep the latest 1,000 per user) is an open question
(§10).

---

## 4. Sync rules (how browsers agree)

Every progress report carries the time it was **observed** in the browser
(`watched_at`). The server keeps the report with the latest observation time.
On PostgreSQL the upsert is:

```sql
INSERT INTO watch_history AS h
       (user_id, video_id, position_seconds, duration_seconds, completed,
        last_watched_at)
VALUES (:user_id, :video_id, :pos, :dur, :completed, :observed)
ON CONFLICT (user_id, video_id) DO UPDATE
   SET position_seconds = EXCLUDED.position_seconds,
       duration_seconds = COALESCE(EXCLUDED.duration_seconds, h.duration_seconds),
       completed        = EXCLUDED.completed,
       last_watched_at  = EXCLUDED.last_watched_at,
       updated_at       = EXCLUDED.updated_at
 WHERE h.last_watched_at <= EXCLUDED.last_watched_at;
```

`:observed` is `min(watched_at, now)` computed in Python with the server's
clock (H3), and `updated_at` is that same `now`. The routes build the
statement with `sqlalchemy.dialects.postgresql.insert` or
`sqlalchemy.dialects.sqlite.insert` by `db.bind.dialect.name`; both support
`on_conflict_do_update(..., where=...)`, so SQLite runs the same rule (H12).
Afterwards one `SELECT` of the caller's rows for those videos tells each
entry apart: the stored `last_watched_at` equals what was sent → `saved`,
otherwise `stale`.

What this gives you:

- **Laptop, then phone.** You watch to 4:10 on the laptop and open the video
  on your phone's browser. It fetches the position and resumes at 4:10, then
  reports newer observations, which win.
- **Late flush.** The laptop watched to 2:00 at 10:00 while its Wi-Fi was
  down, and the phone then watched to 6:00 at 10:30. When the laptop is back
  online at 11:00 it sends `watched_at = 10:00`, which is older than the
  stored 10:30, so it is ignored (`stale`). The phone's 6:00 stays.
- **Two tabs, same video.** Both report; the later observation wins, which is
  the tab you were watching most recently.
- **Fast clock.** A machine 10 minutes ahead sends a `watched_at` in the
  future. Clamping turns it into the server's time, so it can't block other
  browsers' reports for the next 10 minutes.
- **Slow clock.** A machine that is behind looks older than it is, so it can
  lose a race against another browser's real report. That is acceptable: the
  other browser really was more recent, or close to it.
- **Rewinding.** Seeking backwards stores the earlier position. "Latest" means
  the most recent observation, not the furthest point reached. This matches
  YouTube and is where you expect to resume.
- **Retries.** A report sent twice (a retried flush, two tabs flushing the
  same outbox key) has an equal `watched_at` and overwrites itself: `saved`.

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
route requires sign-in (`Depends(get_current_user)`, which reads the
`access_token` cookie; there is no `Authorization` header path) and returns
errors as `{"detail", "code"}` like the rest of the API.

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
| `entries` | 1–50 items; 0 or 51 is a 400 `validation_error`. Duplicate `video_id`s are allowed: the server keeps the one with the latest `watched_at` **before** building the statement (PostgreSQL rejects an `ON CONFLICT DO UPDATE` that touches one row twice). |
| `position_seconds` | Integer, 0–86,400. |
| `duration_seconds` | Optional integer, 1–86,400. |
| `watched_at` | ISO-8601 **with a timezone offset**. A naive timestamp is a 400 `validation_error` (a client bug, not data). |

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
- `expired`: `watched_at` is more than 30 days old. `progress` is null.
  Reported per entry rather than failing the batch, so one old report can't
  keep a whole outbox from ever flushing.

A batch never fails because of one bad video: the results report each entry,
one per distinct `video_id`, in request order. The work is three statements:
load the viewable videos with `Video.id.in_(ids)`, one multi-row upsert, and
one `SELECT` of the caller's rows for those ids.

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
  page doesn't show one.
- `next_cursor` is base64url of `"<last_watched_at ISO, UTC>|<video_id>"` for
  the last item, or null at the end. The next page uses
  `tuple_(last_watched_at, video_id) < (:ts, :id)` (row values work on both
  databases). A cursor that doesn't decode is `400 history_cursor_invalid`.
- `video` has exactly the `FeedItem` shape, so the app parses it with the
  existing `Video.fromJson`. It comes from the same `_feed_fields` /
  `_to_feed_item` helpers as the feed, with `joinedload(Video.user)`. Those
  helpers move into `app/video_views.py` so both routers share them.

### 5.3 `GET /history/positions` — progress for specific videos

Query: `video_ids`, comma-separated, 1–50 UUIDs. More than 50 or a malformed
id is a 400 `validation_error`.

Response `200`: `{ "items": [ <progress>, … ] }`, containing only the videos
that have an entry. A missing id means "never watched". The query runs on the
primary key and doesn't join `videos`: the caller is asking about ids they
already have, and only their own progress comes back.

Used by the watch page (one id, to resume) and by the thumbnail bars (the
ids on screen, ≤ 50 per request).

### 5.4 `DELETE /history/{video_id}` — remove one entry

`204`, also when there was no entry (idempotent).

### 5.5 `DELETE /history` — clear all

`204`. Deletes every row for the caller in one statement.

### 5.6 Route order

Declare `/history/progress` and `/history/positions` before
`/history/{video_id}`, as `video.py` does for `/feed`, `/search`, and
`/mine`. Only `DELETE` uses the path parameter, so there's no clash today,
but the order guards a future `GET /history/{video_id}`.

### 5.7 Summary

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/history/progress` | cookie | Record progress (batch of 1–50) |
| GET | `/history` | cookie | The caller's history, newest first, keyset cursor |
| GET | `/history/positions` | cookie | Progress for up to 50 given videos |
| DELETE | `/history/{video_id}` | cookie | Remove one entry |
| DELETE | `/history` | cookie | Clear all history |

CORS needs no change: `main.py` already allows `GET`, `POST`, and `DELETE`
with `Content-Type` for the origins in `CORS_ORIGINS`.

---

## 6. Backend changes, file by file

| File | Change |
|---|---|
| `app/models.py` | `WatchHistory` model (§3.2). |
| `migrations/versions/0003_watch_history.py` | New table and indexes (§3.3). |
| `app/schemas.py` | `ProgressEntryIn`, `RecordProgressRequest`, `WatchProgress`, `ProgressResult` (`result: Literal["saved", "stale", "not_found", "expired"]`), `RecordProgressResponse`, `HistoryItem` (`video: FeedItem`), `HistoryResponse`, `PositionsResponse`. `watched_at` validator rejects naive datetimes and converts to UTC. |
| `app/video_views.py` (new) | `_feed_fields`, `_to_feed_item`, `_thumbnail_url`, `_manifest_url`, and `viewable_by(user_id)`, a SQL expression (`status = COMPLETED AND (visibility != PRIVATE OR user_id = :me)`), moved out of `routers/video.py`. |
| `app/routers/history.py` (new) | The five routes (§5), the dialect-aware upsert (§4), the cursor encode/decode, and `_utc()` (attach UTC to naive values read back from SQLite). |
| `app/routers/video.py` | Import the moved helpers. No behaviour change. |
| `app/main.py` | `app.include_router(history.router)`. |
| `scripts/seed_sqlite.py`, `tests/support/seed_data.py` | Seeded history rows (§8.1), written after the videos. |
| `../frontend/deploy/nginx.conf.template` | Proxy the new paths to the API: `location ~ ^/((auth\|video\|upload)/\|history(/\|$)\|healthz$)`. `/history` itself has no trailing path, and the app's page is `/feed/history`, so the two never collide. Without this the deployed app gets `index.html` back from every history call. |
| `../scripts/deploy_smoke_test.py` | `GET /history` through the frontend URL without cookies is a JSON 401 `missing_access_token` (proves the proxy route); signed in, `POST /history/progress` for the uploaded video is `saved`, it appears in `GET /history`, and `DELETE /history` empties it. |
| `AGENTS.md`, `README.md`, `../docs/specs/api-and-db-schema-spec.md` | Route table, the new table, and the sync rules. |

The completion poller and the transcoder don't change. Deleting a video
already removes its history rows through the cascade (the SQLite engine turns
foreign keys on for this, `app/db.py`), so `DELETE /video/{id}` doesn't
change either.

---

## 7. Web app changes

The rules in `frontend/AGENTS.md` hold throughout: browser APIs only through
`lib/platform/`, services throw only `ApiException` and callers branch on
`code`, URLs built in `lib/app/routes.dart`, colours and sizes from
`YtColors` / `YtSizes`.

### 7.1 New and changed files

```
lib/
├── platform/
│   ├── browser.dart                 CHANGED  local storage, page-hidden events, keepalive POST
│   ├── browser_web.dart             CHANGED  window.localStorage, visibilitychange/pagehide, fetch(keepalive)
│   ├── browser_stub.dart            CHANGED  in-memory storage, manual hide events
│   ├── video_player.dart            CHANGED  open(..., startAt:)
│   ├── video_web.dart               CHANGED  hls.js startPosition; currentTime after loadedmetadata otherwise
│   └── video_stub.dart              CHANGED  records startAt for tests
├── models/
│   └── watch_progress.dart          NEW  WatchProgress (+ fromJson, fraction, resumeAt), HistoryEntry(video, progress)
├── services/
│   ├── history_service.dart         NEW  record(), list(cursor), positions(ids), remove(id), clear(), exitUrl
│   ├── history_outbox.dart          NEW  per-user pending reports in localStorage (H11)
│   ├── watch_progress_store.dart    NEW  videoId → WatchProgress for the bars; coalesces lookups
│   └── progress_tracker.dart        NEW  PlayerController values → reports (heartbeat, pause, seek, end, exit)
├── cubits/
│   ├── history/history_cubit.dart   NEW  cursor paging, day groups, remove/undo, clear
│   ├── history/history_state.dart   NEW
│   └── session/session_cubit.dart   CHANGED  awaits a beforeLogout hook (flush) before /auth/logout
├── app/
│   ├── routes.dart                  CHANGED  Routes.history = '/feed/history', in signedInOnly
│   ├── router.dart                  CHANGED  the History page inside the ShellRoute
│   └── app.dart                     CHANGED  provide HistoryService/outbox/store; wire session + page events
├── pages/
│   ├── history_page.dart            NEW
│   ├── watch_page.dart              CHANGED  resume lookup, tracker, ResumeChip
│   └── shell/sidebar.dart           CHANGED  "History" guide entry when signed in (full guide and rail)
└── widgets/
    ├── video_thumbnail.dart         CHANGED  optional videoId → WatchedBar over the picture
    ├── watched_bar.dart             NEW  the red bar; asks the store for its video on first build
    ├── video_grid_card.dart         CHANGED  pass videoId to the thumbnail
    ├── video_list_tile.dart         CHANGED  pass videoId; optional trailing action and meta line (History rows)
    └── resume_chip.dart             NEW  "Resumed from 4:14 · Start over"
```

`pages/channel_page.dart` (featured upload) and `pages/your_videos_page.dart`
(table rows) also pass `videoId` to their `VideoThumbnail`. Nothing else in
the feed, search, channel, or My Videos cubits changes: the bars fetch their
own data (§7.6).

### 7.2 Models

```dart
class WatchProgress extends Equatable {
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

class HistoryEntry extends Equatable {
  final Video video;          // the existing Video.fromJson
  final WatchProgress progress;
}
```

### 7.3 Platform additions (`lib/platform/browser.dart`)

```dart
abstract class Browser {
  // ...existing members...

  /// window.localStorage. Null when storage is blocked (some private
  /// modes); callers then keep reports in memory only.
  String? readLocal(String key);
  void writeLocal(String key, String value);
  void removeLocal(String key);
  Iterable<String> localKeys(String prefix);

  /// Calls [onHidden] when the tab is hidden or the page is being unloaded
  /// (`visibilitychange` → hidden, `pagehide`), and [onVisible] when it is
  /// shown again. Returns the unsubscribe function.
  void Function() listenForVisibility({
    required void Function() onHidden,
    required void Function() onVisible,
  });

  /// `fetch(url, {method: 'POST', keepalive: true, credentials: 'include'})`
  /// with a JSON body: the one request a closing tab can still send. No
  /// answer is read.
  void postOnExit(String url, String json);
}
```

`FakeBrowser` in `test/pages/harness.dart` gains a map for storage, a
`hide()` / `show()` pair, and a list of exit posts.

### 7.4 Recording progress: `ProgressTracker` and `HistoryOutbox`

**`ProgressTracker`** is created by `WatchPage` next to its
`PlayerController` (only when signed in) and listens to the controller's
`PlayerValue` (`position`, `duration`, `playing`, `ended`). The `<video>`
element's `timeupdate` drives `position` about four times a second.

| Signal | Action |
|---|---|
| `position` changes while `playing` | Add the wall-clock time since the last change to played time if the jump matches it (within 1.5 s); a bigger jump is a **seek** and doesn't count. |
| `playing` becomes true | Start a 15 s heartbeat timer. |
| `playing` becomes false, `ended` becomes true | Report now; stop the timer. |
| A seek | Report after it settles (debounced 1 s). |
| `WatchPage.dispose` (navigating away in the app) | Report now. |
| Tab hidden or page unloading (`Browser.listenForVisibility`) | Report now, then send this user's whole outbox with `Browser.postOnExit`. |

Nothing is reported until 5 s have been played (H10). After that, each report
is `{videoId, position, duration, watchedAt: DateTime.now().toUtc()}`.

Reports go into **`HistoryOutbox`** first, never straight to the network:

- One `localStorage` key per video: `ytp.history.<userId>.<videoId>`, value
  the report as JSON. A write replaces the key only if its `watchedAt` is
  newer, so a tab can't overwrite a newer report from another tab (H11).
- `flush()` sends up to 50 at a time to `POST /history/progress`. For each
  result (`saved`, `stale`, `not_found`, `expired`) it removes the key **only
  if it still holds the report that was sent**, so a newer report written
  during the request survives. A network error or a 5xx keeps everything for
  the next flush. A 401 goes through the existing refresh interceptor; if the
  session really expired, the reports stay until this user signs in again.
- Flushes run after each report (debounced 2 s), when the tab becomes
  visible again, after sign-in and session restore, and every 60 s while the
  outbox isn't empty.
- Keys older than 30 days are dropped without sending (the server would
  answer `expired`).
- **Sign out:** `SessionCubit.logout` awaits a `beforeLogout` hook that
  flushes (3 s timeout) while the cookies still work, then the outbox deletes
  every key for this user. On a shared computer the next person never sees
  or sends this user's history.
- With `localStorage` unavailable, the outbox keeps reports in memory: the
  page works, only the close-the-tab guarantee is lost.

`postOnExit` sends the outbox as one `RecordProgressRequest` and leaves the
keys in place: a closing tab can't read the answer, so the next visit's flush
re-sends them, and an equal `watched_at` overwrites itself (§4). In
production the app and API share an origin (nginx proxy), so the keepalive
POST needs no CORS preflight. In a cross-origin dev setup the browser may
refuse it; the outbox still delivers on the next visit.

When a report is written, the tracker also puts it in `WatchProgressStore`,
so the thumbnail bars show it as soon as you leave the watch page.

### 7.5 Resume on the watch page

`PlayerController.open` gains `Duration? startAt`. The web controller passes
it to hls.js as `startPosition` (so the first segment fetched is the right
one) and, for native HLS in Safari and for dash.js, sets `currentTime` on
`loadedmetadata`.

1. When the page opens and the session is signed in, look up the position in
   parallel with `VideoDetailCubit.load`:
   `HistoryService.positions([id])`. Skip the lookup when the page was opened
   from History (the store already has a fresh entry for this video).
2. Use the **newer** of the server's answer, the store's entry, and any
   report for this video in the outbox (progress this browser hasn't synced
   yet beats an older server value).
3. `_onDetail` opens the player when the detail is ready, passing
   `startAt: progress?.resumeAt`.
4. Don't hold playback for the lookup longer than 1.5 s after the page
   opened. If it hasn't answered by then, start from 0 and ignore the late
   answer: seeking under the viewer's hands is worse than not resuming.
5. When the video resumed, `ResumeChip` sits over the bottom-left of the
   player for 4 s: "Resumed from 4:14 · **Start over**". *Start over* calls
   `seekTo(Duration.zero)`. The chip hides with the controls in fullscreen.

View counting (`POST /video/{id}/view` once `started`) is unchanged.

### 7.6 Progress bars on thumbnails

- `VideoThumbnail` gets an optional `videoId`. When it's set and someone is
  signed in, a `WatchedBar` is drawn along the bottom: a 3 px
  `YtColors.red` bar at `fraction` over a translucent grey track, under the
  duration badge. Semantics adds "Watched 41 %".
- `WatchedBar` asks `WatchProgressStore` for its video in `initState` and
  listens to that video's `ValueListenable<WatchProgress?>`.
- **`WatchProgressStore`** collects the ids asked for during one frame,
  drops the ones it already knows, and sends one
  `GET /history/positions` per 50. Every surface that shows thumbnails (home
  grid, search, channel shelves and featured upload, up next, Your videos,
  History) gets bars with no change to its cubit, and a page of 24 cards
  costs one request. A failure is ignored: the bars are decoration.
- Signed out, the store makes no requests and every bar is empty. On sign-out
  it is cleared.
- Entries arrive from four places: positions lookups, the tracker's reports,
  `stale` answers (the server's newer entry), and History pages. Removing
  from history or clearing it removes them.

### 7.7 History page (`/feed/history`)

- Reached from **History** in the guide (full sidebar, the 72 px rail, and
  the drawer), shown only when signed in, between *Your videos* and *Upload*.
  The path is in `Routes.signedInOnly`, so a signed-out visitor goes to Sign
  in and back.
- Layout follows YouTube's desktop history in the app's existing look: a
  "Watch history" heading, then the rows in a column up to 1,000 px wide, and
  on wide screens a right column with **Clear all watch history**. On narrow
  screens that action moves under the heading.
- `HistoryCubit` follows `FeedCubit`'s shape but pages by `next_cursor`: it
  has `load`, `refresh`, `loadMore` (via the existing `LoadMoreListener`),
  `remove(id)` (optimistic, restored on error), `undo()`, and `clear()`.
- Rows are grouped under day headers — *Today*, *Yesterday*, weekday names
  for the last week, then dates (`formatDate`) — computed in the cubit from
  `lastWatchedAt` in local time.
- Each row is a large `VideoListTile` (as on search results) whose thumbnail
  carries the bar. Its meta line reads "Watched 2 hours ago" (`timeAgo`) and
  its trailing ✕ button (tooltip *Remove from watch history*) removes it, with
  an *Undo* snackbar. Undo re-sends the entry's last progress with its
  original `watchedAt`, so it returns to the same place in the list.
- *Clear all watch history* asks for confirmation, then calls
  `DELETE /history`, empties the list and the `WatchProgressStore`, and
  deletes this user's outbox keys. Otherwise a pending report would add an
  entry straight back.
- Empty state: "Videos you watch will show up here." Errors use
  `ErrorView.fromException` with *Retry*, like the other lists.
- Clicking a row goes to `/watch?v=` (an `AppLink`, so middle-click opens a
  tab). The entry is already in the store, so the watch page skips the
  lookup. Coming back runs `refresh()`, because the video just watched moves
  to the top.

### 7.8 Wiring (`app/app.dart`)

- Create `HistoryService` (on the `api` Dio), `HistoryOutbox`, and
  `WatchProgressStore` next to `VideoService`, and provide them with the
  other repositories. `YtpApp` takes test doubles for them, as it does for
  the other services.
- Listen to `SessionCubit`: on `SessionAuthenticated(user)`, open the outbox
  for `user.id` and flush it; on `SessionUnauthenticated`, close the outbox
  (its keys stay unless this was an explicit sign-out) and clear the store.
- One `Browser.listenForVisibility` subscription at the root: hidden →
  the active tracker reports and the outbox posts on exit; visible → flush.

### 7.9 Backend without history

If `POST /history/progress` or `GET /history/positions` answers 404 with code
`not_found` (FastAPI's unknown-path answer, from a backend that predates this
feature), history turns itself off for the page load: the tracker stops
recording, the store stops looking things up, the outbox keeps what it has,
and the History page shows "Watch history isn't available on this server."
The backend ships first (§9), so this matters only for a frontend deployed
ahead of it.

---

## 8. Testing

### 8.1 Backend

Uses the existing harness: `tests/sanity/` (unit tests and the app
in-process on SQLite) and `tests/integration/` (HTTP against the test server
that `scripts/run_pipeline.sh` starts, with the `anon`, `alice`, and `bob`
fixtures).

**Seed data** (`tests/support/seed_data.py`, written by
`scripts/seed_sqlite.py`): `HISTORY` rows for Alice on `guitar` (completed),
`mountains` (half-way), `timelapse` (just started), and on her own `diary`
(PRIVATE, hers, so visible), with fixed `last_watched_at` values; none for
Bob.

Integration tests:

- Upsert: first report inserts; a newer one updates; an older one is `stale`
  and returns the stored entry; equal `watched_at` overwrites (retry).
- A future `watched_at` is clamped to the server's time.
- A naive timestamp, 0 entries, or 51 entries is a 400; a report older than
  30 days is `expired` and the rest of its batch is still `saved`.
- Duplicate ids in one batch: one result, the latest `watched_at` wins.
- `completed` at 94 %, 95 %, 10 s left, and with a null duration.
- A position past the duration is clamped.
- `not_found` for a missing video, Alice's `diary` reported by Bob,
  `rendering` (PROCESSING), and `broken` (FAILED). Alice's own `diary` is
  `saved`.
- `GET /history`: Alice's seeded order; paging with `limit=2` walks every row
  exactly once while Bob reports in between; Bob watches `mountains`, Alice
  makes it PRIVATE (`PATCH`), it disappears from Bob's history, and returns
  when she makes it PUBLIC again (the test restores it); a bad cursor gives
  `history_cursor_invalid`.
- `GET /history/positions`: only the caller's rows; 51 ids or a malformed id
  is a 400.
- `DELETE` one entry, and clear all; deleting a video removes its rows.
- Every route without cookies is a 401 `missing_access_token`.

Sanity tests: the cursor round-trips; `_utc()`; the completion rule; the
upsert builds for both dialects.

Against the compose PostgreSQL once per schema change: `alembic upgrade
head`, then `alembic check`. The SQLite tests can't catch a drift between the
model and the revision.

### 8.2 Web app

On the VM, with the existing tools (mocktail, bloc_test,
http_mock_adapter, the `harness.dart` fakes):

- `WatchProgress`: `fraction`, `resumeAt` (completed, under 5 s, normal).
- `HistoryService`: request shapes, parsing the four `result` values, cursor
  passthrough, `not_found` turning history off.
- `HistoryOutbox` (over `FakeBrowser` storage): a write keeps only the newest
  report per video, also when two outboxes (two tabs) share the storage;
  flush removes answered keys but not ones rewritten during the request, and
  keeps everything after a network error; batches of 50; drops keys over 30
  days; separate keys per user; sign-out deletes this user's keys only.
- `ProgressTracker` (a scripted `PlayerController` and `fake_async`):
  nothing before 5 s of play; a heartbeat every 15 s; reports on pause, seek
  (debounced), end, dispose, and `hide()`; seeks don't count as played time.
- `WatchProgressStore`: ids asked for in one frame make one request; known
  ids aren't asked again; nothing is asked while signed out.
- `HistoryCubit`: paging by cursor, optimistic remove and restore on error,
  undo, clear, day groups across midnight and a week boundary.
- Widget tests over the whole app (`browse_test.dart` style): the History
  page (list, empty, error, remove + undo, clear confirmation), the guide
  entry only when signed in, `/feed/history` redirecting a signed-out
  visitor, the bar on a home-grid card, and the watch page opening the player
  with `startAt` plus `ResumeChip` and *Start over*.

### 8.3 Browser E2E (`scripts/run_pipeline.sh` step 4)

Extend `integration_test/seeded_flow_test.dart`: sign in as Alice, open
History from the guide, see the seeded rows in order with their bars, see a
bar on the `guitar` card on Home, remove `timelapse` and undo, then clear all
and see the empty state. The seeded videos point at a CDN that doesn't exist
(`cdn.test`), so the E2E can't play anything: recording and resume are
covered by the widget tests and the manual check below.

### 8.4 Manual check on a deployed stack

Two browsers (say Chrome on a laptop and Safari on a phone) on one account:
watch to 2:00 in A → open in B, it resumes at about 1:58 with the chip. In A,
go offline (DevTools → Network → Offline), watch to 3:00, close the tab; watch
to 5:00 in B; bring A back online and open the app → B's 5:00 stays. Close a
tab mid-video and reopen the video → it resumes within 15 s of where it
stopped. Remove an entry in A → gone in B after a refresh. Clear all in B →
A's History is empty after a refresh. Sign out in A → the `ytp.history.*`
keys are gone from `localStorage`.

---

## 9. Rollout and milestones

The backend ships first. It's additive, so the current app is unaffected.

| Step | Scope | Done when |
|---|---|---|
| **M1** Schema | Model, migration `0003`, `video_views.py` refactor | `alembic upgrade head` and `alembic check` pass on a fresh compose PostgreSQL and on a copy of the current schema; `run_pipeline.sh --only 1` green |
| **M2** API | `routers/history.py`, schemas, seed rows, tests, docs; nginx route; smoke-test checks | §8.1 green in `run_pipeline.sh`; the deployed `/history` answers JSON through the frontend URL |
| **M3** Recording + resume | `Browser` additions, `WatchProgress`, `HistoryService`, `HistoryOutbox`, `ProgressTracker`, `startAt`, watch page changes, session and visibility wiring | Unit and widget tests green; manual: resume works across two browsers |
| **M4** History page | `HistoryCubit`, `HistoryPage`, route, guide entry, remove/undo/clear | Widget tests and the E2E (§8.3) green |
| **M5** Thumbnail bars | `WatchProgressStore`, `WatchedBar`, `videoId` through the thumbnails | Widget test green; bars update after leaving the watch page |
| **M6** Hardening | No-history fallback (§7.9), the manual check (§8.4), metrics on the write rate, `frontend/README.md` (pages table; drop history from "Not built") and `frontend/PLAN.md` §16 W9 | Checklist done |

M1 and M2 deploy on their own (backend, then a frontend image for the nginx
route). M3–M5 can each be a separate PR. Deploy with the runbook
(`DEPLOY_AWS.md` §10 for the update path).

---

## 10. Risks and open questions

### Risks

- **Cognito `GetUser` per request.** Every authenticated request calls
  Cognito (`app/deps.py`). 1,000 concurrent viewers × 1 write / 15 s ≈ 67
  `GetUser` calls/s, plus the positions lookups as people browse, on top of
  normal traffic, and Cognito's API quotas are per account. Mitigations here:
  the 15 s cadence, batched flushes (H5), and one positions request per
  screenful (§7.6). The real fix is to verify the access-token JWT locally
  against the pool's JWKS and only call `GetUser` when needed. That change is
  worth doing for the whole API, separately from this feature.
- **Write load on PostgreSQL.** The same 1,000 viewers make about 67
  upserts/s on a narrow table, which is fine for RDS. If it grows by orders of
  magnitude, buffer reports in Redis and have a worker flush them every few
  seconds. The API contract wouldn't change.
- **The last seconds before a tab closes.** `pagehide` and `visibilitychange`
  fire on close, reload, and switching apps on a phone, and the outbox is
  written synchronously, so the report survives; whether the keepalive POST
  gets out depends on the browser. A browser crash loses at most one
  heartbeat (≤ 15 s).
- **Throttled background tabs.** Browsers slow timers in hidden tabs, so the
  heartbeat may stretch while a video plays in a background tab. The hidden
  event already reported the position at that moment, and the next visible
  event reports again.
- **Shared computers.** Progress waits in `localStorage` under the user's id
  until it's sent. An explicit sign-out deletes it; an expired session keeps
  it (so nothing is lost) until that user signs in again. It holds video ids
  and positions only, never a token.
- **Clock skew.** Covered by H3 and §4. A machine with a slow clock can lose a
  race to another browser it was actually concurrent with. Accepted.
- **`startPosition` across players.** hls.js honours it before the first
  segment; native Safari HLS and dash.js seek after `loadedmetadata`, which
  can show the first frame briefly. Check during M3 in Safari and with a
  DASH-only video.

### Open questions

1. **Retention:** keep everything, or cap at the newest N per user (for
   example 1,000) with a nightly prune?
2. **Pause history:** add a `users.history_paused` flag that makes
   `POST /history/progress` a no-op? It's cheap to add later; it's not in v1.
3. **Own videos:** record history when an owner watches their own upload
   (from Your videos, say)? This plan says yes, like YouTube.
4. **Completion threshold:** is 95 % / 10 s right for short videos? For a
   20 s clip, the 10 s rule marks it complete at the halfway point. A
   minimum-duration condition may be needed.
5. **Unavailable videos in history:** hide them (this plan), or show a grey
   "This video is unavailable" row as YouTube does?
6. **Search in history:** YouTube has it. It would need a title filter on
   `GET /history`. Not in v1.
7. **Other tabs' bars:** a tab doesn't see progress another tab records until
   it fetches positions again. Listening to the `storage` event would update
   the store live; worth it?
8. **Mockup:** the Figma file this app's look comes from may have a History
   frame. If it does, §7.7's layout should follow it instead of YouTube's
   current page.

---

## 11. Changes from the mobile version of this plan

| Topic | Mobile plan | This plan | Why |
|---|---|---|---|
| Client | Android/iOS app on `feature/flutter-frontend` | The Flutter web app on `main` | The mobile targets were dropped (`frontend/PLAN.md` §16) |
| Auth on the new routes | Cookie or Bearer | Cookie only | The backend removed the `Authorization` path; the browser sends the HttpOnly cookie |
| Player events | `better_player_plus` events (`progress`, `seekTo`, ...) | `PlayerController`'s `PlayerValue`; seeks detected from position jumps | The web app draws its own controls over `<video>` + hls.js / dash.js |
| Outbox | One JSON file per user in app support storage | One `localStorage` key per (user, video) | No file system in a browser; per-key writes are safe across tabs |
| Exit handling | `AppLifecycleState.paused` / `hidden` | `visibilitychange` / `pagehide`, plus a keepalive `fetch` | Browser lifecycle; a closing tab can still send one request |
| Resume | `BetterPlayerConfiguration(startAt:)` | `PlayerController.open(startAt:)` → hls.js `startPosition` | Same intent on the web player |
| History entry point | Account menu on Home | Guide entry (sidebar, rail, drawer) and `/feed/history` | The web app's navigation is the guide; real URLs are shareable and reloadable |
| Bars | Per-page `positions()` calls from Home and My Videos | Thumbnails ask a store that coalesces lookups | Thumbnails now appear on six surfaces; one mechanism covers all |
| Batch rejects | An entry older than 30 days failed the whole batch (400) | Per-entry `expired` | A 400 batch stays in the outbox and would be re-sent forever |
| Duplicate ids in a batch | "Latest wins" | Deduplicated in Python before the upsert | PostgreSQL rejects an `ON CONFLICT DO UPDATE` that hits one row twice |
| SQL | PostgreSQL-only (`LEAST(..., now())`, `= ANY(:ids)`, `RETURNING`) | Dialect-built upsert, Python `now()`, `in_()`, a follow-up `SELECT` | The tests and E2E run on SQLite |
| Backend tests | "No tests yet; add pytest with PostgreSQL" | The existing SQLite harness, seed rows, `alice`/`bob` fixtures | `backend/tests/` and `scripts/run_pipeline.sh` exist now |
| Deployment | Not covered | nginx proxies `/history`; smoke test checks it | Same-origin deploy: an unproxied path returns `index.html` |
| Signed-out visitors | Not a case (the app required sign-in) | No recording, no bars, History redirects to Sign in | The web app lets anyone browse |
| Older backends | Fallback for the in-app server URL in dev builds | Fallback only for a frontend deployed ahead of its backend | The web app has no in-app server URL |
