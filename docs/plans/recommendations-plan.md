# Recommendations — Implementation Plan

Signed-in users get a home feed picked for them and an *Up next* column of
videos related to the one they're watching. Signed-out visitors get a feed of
what is trending and new. This plan covers the signals the engine needs, how
recommendations are built and served, the API, the changes to the web app,
how to measure whether it works, and the order to build it in.

It builds on:

- **watch history** (`watch-history-plan.md`): the `watch_history` table
  (migration `0003`), `app/video_views.py`, and the web app's
  `Browser.listenForVisibility` / `postOnExit`. History is the strongest
  signal here, so its M1–M3 must ship before this plan's M3;
- the backend in `backend/app/`, its SQLite test harness, and the Redis it
  already uses (`app/cache.py`);
- the Flutter web app in `frontend/` and its ECS deployment, where nginx
  proxies `^/((auth|video|upload)/|healthz$)` to the API on the same origin.

Today the home feed is newest-first or most-viewed (`GET /video/feed`,
`sort=latest|popular`), and *Up next* is the same feed or the creator's
channel (`_UpNext` in `frontend/lib/pages/watch_page.dart`).

---

## Contents

1. Goals and non-goals
2. Key decisions
3. Database schema
4. How recommendations are built
5. API
6. Backend changes, file by file
7. Web app changes
8. Measuring it
9. Testing
10. Rollout and milestones
11. Risks and open questions

---

## 1. Goals and non-goals

**Goals**

- A home feed ranked for each signed-in user from what they watched, liked,
  and subscribed to; trending and new videos for everyone else.
- *Up next* on the watch page from videos related to the one playing.
- The signals the engine needs and the app lacks today:
  - a **category** and **tags** on every video;
  - **like / dislike**;
  - **subscriptions** to channels, with a Subscriptions page at
    `/feed/subscriptions`;
  - **Not interested** on any card;
  - **impressions and clicks**, which videos were shown and which were opened.
- Every recommended item carries a **reason** (*Because you watched …*,
  *From a channel you subscribe to*, *Trending*, *New*), used in the card
  menu and in the measurements.
- Click-through and watch time per surface, and an A/B comparison against
  today's newest-first feed.

**Non-goals for v1** (see §11)

- A learned ranking model or a training pipeline. The structure leaves room
  for one (R1).
- Streaming infrastructure (Kinesis, Kafka). An hourly batch job is enough.
- A vector database. Embeddings, when they come (M6), are compared in the
  batch job.
- Personalised search ranking.
- Notifications for new uploads from subscriptions.
- Signals from signed-out visitors (no anonymous id, so no consent banner).
- *Don't recommend channel*.

---

## 2. Key decisions

| # | Decision | Why |
|---|---|---|
| R1 | Two stages: **candidate sources** each propose videos, then one **ranker** scores and orders them. v1's ranker is a weighted formula with configurable weights. | The catalogue is small and there's no training data until impressions exist. A model can replace the ranker later without touching the sources, the API, or the app. |
| R2 | The heavy work runs **offline** in an hourly batch job that writes `video_neighbors` and `video_trending`. A request reads only those indexed tables plus the caller's own rows. | Co-watch counting grows with users × history. Request latency must not. |
| R3 | Every query on the request path runs on PostgreSQL **and SQLite**. The batch job aggregates in Python. Embeddings (M6) are stored as bytes and compared in the job; there's no `pgvector`. | Same as watch history H12: the tests and the browser E2E run on SQLite. |
| R4 | **Trending** is built from deduplicated, signed-in signals: distinct watchers from `watch_history` (5 s of play at least, history H10) and likes. Not from `views_count`. | `POST /video/{id}/view` has no per-viewer dedupe, so replaying a video inflates it. |
| R5 | A co-watch pair counts only when at least `RECS_MIN_COWATCH_USERS` (default 3) **distinct users** watched both. | With few users, *people who watched X also watched Y* would reveal one person's history to anyone who opens X. |
| R6 | Page 1 of the home feed builds a fresh list of up to 200 videos and stores it in Redis under a `rec_id`. Later pages are slices of that frozen list. | Stable paging: nothing repeats or goes missing while you scroll, even though the ranking moves. The app keeps `page`/`limit` and `FeedCubit`. |
| R7 | The new routes live under **`/video/`**, and the new routers are included **before** `video.router`. | nginx already proxies `video/`, so unlike `/history` there's no proxy change. Including them first stops `GET /video/{video_id}` from capturing `/video/recommended`, which would give a 422 because `recommended` isn't a UUID. |
| R8 | Responses reuse `FeedItem` (plus an optional `reason`) and `FeedResponse` paging (plus `rec_id` and `bucket`). | The app parses them with the existing `Video.fromJson` and pages them with `FeedCubit`. |
| R9 | Filters run at **serve time**, never only in the batch job. Only listed videos (PUBLIC + COMPLETED), never the caller's own, never completed or watched in the last 3 days, never dismissed, never disliked. | The batch tables can be an hour old. A video made private must disappear at once. |
| R10 | **Diversity**: at most 2 videos from one creator in any 8 consecutive slots, and at least 1 in 8 from the *fresh* source. | Stops one channel filling the feed, and gives new uploads impressions (cold start for videos). |
| R11 | **Cold start for users**: signed out, or signed in with no signals → trending blended with fresh. A single watch, like, or subscription is enough to start personalising. | Everyone gets a feed, and personalisation starts as soon as there is anything to go on. |
| R12 | Per-user state (my reaction, my subscriptions) is never put in the shared `video:meta` cache or in `GET /video/{id}`. It has its own reads. | Same as watch history H9: the cache is shared by every viewer, and the public reads take no auth. |
| R13 | Impressions are **best-effort**: buffered in memory, sent every 10 s and on page hide (`postOnExit`), and kept 30 days. There's no `localStorage` outbox. | Losing a few is harmless. They serve measurement and fatigue, not user data. |
| R14 | A server flag and a rollout bucket: `RECS_ENABLED`, and `RECS_ROLLOUT_PERCENT` applied to `hash(user_id)`. Outside the rollout, `/video/recommended` returns the newest-first feed in the same shape with `bucket: "control"`. | Rolling back needs no app deploy, and control vs treatment is a real A/B comparison. |

---

## 3. Database schema

Every new table follows the existing conventions: UUID keys, `ON DELETE
CASCADE` foreign keys, UTC timestamps (watch history §3.2). The migrations are
additive only, so tasks still running older code keep working while a deploy
rolls out.

### 3.1 Category and tags (migration `0004_tags_and_category`)

- **`videos.category`**, `String(32)`, nullable: one code from a fixed list
  in `app/categories.py`. The codes follow YouTube's categories: `film`,
  `autos`, `music`, `pets`, `sports`, `travel`, `gaming`, `people`, `comedy`,
  `entertainment`, `news`, `howto`, `education`, `science`, `nonprofits`.
  Existing rows stay null, and null matches nothing in content similarity.
- **`video_tags`**:

| Column | Type | Notes |
|---|---|---|
| `video_id` | `uuid` | FK → `videos.id` `ON DELETE CASCADE` |
| `tag` | `varchar(30)` | Normalised (below) |

Primary key `(video_id, tag)`; index `ix_video_tags_tag` on `(tag)`, which the
batch job uses to find videos that share a tag.

**Tag rules**, applied by the schema validator:

- trim, lower-case, collapse runs of spaces;
- 1–30 characters of letters, digits, spaces, and hyphens;
- at most 10 per video, duplicates removed.

Anything else is a 400 `invalid_tag`.

### 3.2 Reactions, subscriptions, Not interested (migration `0005_engagement`)

**`video_reactions`**

| Column | Type | Notes |
|---|---|---|
| `user_id` | `uuid` | FK → `users.id` cascade |
| `video_id` | `uuid` | FK → `videos.id` cascade |
| `value` | `smallint` | `1` like, `-1` dislike. "None" deletes the row. |
| `updated_at` | `timestamptz` | |

Primary key `(user_id, video_id)`; index on `(video_id)`; check
`value IN (1, -1)`.

**`videos.likes_count`**, `integer NOT NULL DEFAULT 0`, is kept in the same
transaction as the reaction write, like `views_count`. Dislikes are stored
but not counted on the video (open question 9).

**`subscriptions`**

| Column | Type | Notes |
|---|---|---|
| `subscriber_id` | `uuid` | FK → `users.id` cascade |
| `channel_id` | `uuid` | FK → `users.id` cascade |
| `created_at` | `timestamptz` | |

Primary key `(subscriber_id, channel_id)`; index on `(channel_id)` for the
subscriber count; check `subscriber_id <> channel_id`.

**`not_interested`**: `(user_id, video_id, created_at)`, primary key
`(user_id, video_id)`, both FKs cascade.

### 3.3 Recommendation tables (migration `0006_recs`)

**`video_neighbors`**, written only by the batch job:

| Column | Type | Notes |
|---|---|---|
| `video_id` | `uuid` | FK cascade |
| `neighbor_id` | `uuid` | FK cascade |
| `source` | `varchar(16)` | `cowatch` or `content` |
| `score` | `float` | 0–1 |

Primary key `(video_id, source, neighbor_id)`; index
`(video_id, score DESC)`. At most 50 rows per (video, source).

**`video_trending`**: `video_id` (PK, FK cascade), `score float` (0–1),
`built_at`.

**`rec_events`**, append-only:

| Column | Type | Notes |
|---|---|---|
| `id` | `bigint` | PK. `BigInteger().with_variant(Integer, "sqlite")`, because SQLite only autoincrements an `INTEGER PRIMARY KEY`. |
| `user_id` | `uuid` | FK cascade |
| `video_id` | `uuid` | FK cascade |
| `type` | `varchar(12)` | `impression` or `click` |
| `surface` | `varchar(16)` | `home`, `related`, `subscriptions` |
| `rec_id` | `varchar(40)` | The list it came from |
| `source` | `varchar(16)` | Winning candidate source, from the item's reason |
| `position` | `integer` | 0-based slot |
| `bucket` | `varchar(12)` | `treatment` or `control` (R14) |
| `occurred_at` | `timestamptz` | Clamped to the server clock |

Indexes: `(user_id, video_id, occurred_at)` for fatigue (§4.2), and
`(occurred_at)` for pruning. The batch job deletes rows older than 30 days.

### 3.4 Embeddings (migration `0007_video_embeddings`, M6)

**`video_embeddings`**: `video_id` (PK, FK cascade), `model varchar(64)`,
`vector` (`LargeBinary`, float32 little-endian), `text_hash varchar(64)`
(SHA-256 of the embedded text, so unchanged videos aren't re-embedded),
`updated_at`.

### 3.5 Size

At 100,000 videos, `video_neighbors` holds at most 10 M rows (about 1 GB with
indexes). One million daily users × 50 impressions × 30 days is about
1.5 billion `rec_events` rows, which is too many for RDS. Before traffic
reaches that, move events to S3 through Firehose and query them with Athena
(§11). v1 sizes are far below this.

---

## 4. How recommendations are built

### 4.1 The batch job (`app/workers/recs_builder.py`)

It runs hourly as an ECS scheduled task (`python -m app.workers.recs_builder
--once`), holding a PostgreSQL advisory lock (`pg_try_advisory_lock`) so two
runs never overlap. On SQLite it runs unlocked. Each step is a function of
`(db, now)` so the tests call it directly.

1. **Engaged watches.** A `watch_history` row counts as engaged when any of
   these holds:
   - it is `completed`;
   - `position_seconds ≥ 30 %` of the duration;
   - `position_seconds ≥ 120`.

   Use the last 90 days, the latest 200 per user. A like counts as an engaged
   watch too.
2. **Co-watch neighbours.** For each user, pair each engaged video with the
   next 20 in their watch order, a rough "same session" window that keeps the
   work at about 4,000 pairs per user. Then:
   - `co(a, b)` = the number of distinct users who have the pair;
   - `n(a)` = the number of distinct users with an engaged watch of `a`;
   - `score = co(a, b) / sqrt(n(a) · n(b))` (cosine);
   - drop pairs with `co` below `RECS_MIN_COWATCH_USERS` (R5);
   - keep the top 50 per video.
3. **Content neighbours.** Among listed videos that share a tag or a
   category (found through `ix_video_tags_tag`, so it's never all pairs):
   `score = 0.6 · jaccard(tags) + 0.3 · same_category + 0.1 · same_creator`.
   Keep the top 50 with `score ≥ 0.1`. From M6 on, the score becomes
   `0.5 · cosine(embeddings) + 0.5 ·` the tag score.
4. **Trending.** For each listed video, sum over the last 14 days with a
   decay of `exp(−age_hours / 72)`:
   - each distinct watcher, 1.0 if engaged and 0.3 if only started;
   - plus 2.0 per like.

   Normalise by the maximum to 0–1, and keep the top 500.
5. **Write.** Each table is replaced in one transaction (delete, then insert).
   PostgreSQL readers see the old rows until the commit, so a request never
   reads a half-built table.
6. **Prune** `rec_events` older than 30 days.
7. **Publish** a new build id: `SET recs:build <unix ts>`. The cached lists
   (§4.2–4.3) include it in their keys, so they go stale together.

Steps 1–4 read everything into Python. That's fine up to roughly 10 million
history rows and 100,000 videos (minutes, a few hundred MB). Past that, move
step 2 to a SQL self-join or a Spark/Athena job; the tables it writes stay
the same (§11).

### 4.2 Home feed for a signed-in user

**Seeds.** The user's last 20 engaged watches, each weighted
`exp(−days_since / 14)`, plus their likes from the last 90 days at weight 1.0.

**Candidate sources.** Each returns videos with a source score from 0 to 1:

| Source | From | Score | Cap |
|---|---|---|---|
| `neighbors` | `video_neighbors` of the seed ids (both sources; `content` × 0.7) | Σ over seeds of seed weight × neighbour score, normalised | 300 |
| `subscriptions` | listed videos from subscribed channels, uploaded in the last 30 days | `exp(−age_days / 7)` | 100 |
| `trending` | `video_trending` | its score | 100 |
| `fresh` | listed videos uploaded in the last 7 days, newest first | `1 − age_days / 7` | 50 |

**Filter** (R9), in SQL with `Video.id.in_(candidate_ids)`, at most 550 ids:

- listed only (`_LISTED`);
- `user_id ≠ me`;
- drop rows in my `not_interested`, rows with my reaction −1, my completed
  history, and my history with `last_watched_at` in the last 3 days.

**Score**

```
score = 1.0·neighbors + 0.8·subscriptions + 0.4·trending + 0.2·fresh
        − min(0.6, 0.15 × unclicked impressions of this video to me in 7 days)
```

The weights are settings (`RECS_W_NEIGHBORS`, …), so tuning needs no code
change. The fatigue term reads `rec_events` through its
`(user_id, video_id, occurred_at)` index.

**Re-rank** greedily for diversity (R10). Keep the first 200.

**Reason.** The source that added the most to the score:

- `neighbors`: *Because you watched «title of the seed that contributed most»*;
- `subscriptions`: *From «channel»*;
- `trending`: *Trending*;
- `fresh`: *New*.

**Store** the ordered ids and reasons in the Redis hash `recs:home:<user_id>`,
field `<rec_id>` (a new UUID). The hash expires 30 minutes after the last
write. Only the 3 newest fields are kept, so a second tab doesn't break the
first tab's paging.

Page 1 takes about 7 indexed queries and one Redis write. Later pages are one
Redis read plus loading `limit` videos by id. The target is under 150 ms p95
for page 1.

**Signed out, or no signals (R11).** Trending and fresh only, without the
filters that need a user. The list is cached for everyone under
`recs:home:anon:<build>` for 5 minutes, with `rec_id = "anon-<build>"`.

**Never empty.** If the batch tables are empty (the first deploy, before the
job has run) or Redis is down, the list falls back to the newest-first feed.
Without Redis, every page is rebuilt and the app drops duplicates (§7.2).

### 4.3 Related videos (*Up next*) for video V

| Source | Score |
|---|---|
| `video_neighbors` of V, `cowatch` | its score × 1.0 |
| `video_neighbors` of V, `content` | its score × 0.7 |
| V's creator's latest listed uploads | `0.3 × exp(−age_days / 30)` |
| `trending`, as fill | its score × 0.2 |

V itself is excluded, along with the filters from R9 that don't need a user.
The ordered list of 40 is cached under `recs:related:<V>:<build>` for 10
minutes. Signed in, the per-user filters and fatigue run after the cache, and
20 come back. The reasons are *Related*, *From «creator»*, and *Trending*.

An UNLISTED or (own) PRIVATE V gets related videos too, because the caller can
watch it. Its neighbours are always listed videos.

### 4.4 Subscriptions feed

Listed videos from subscribed channels, newest first, paged with
`page`/`limit` like the feed. It's a plain query with no ranking.

### 4.5 Privacy and deletion

- **Seeds are read at request time** from `watch_history`, `video_reactions`,
  and `subscriptions`. Removing an entry from history or clearing it therefore
  affects the next page 1. `DELETE /history` and `DELETE /history/{id}` also
  `DEL recs:home:<user_id>`.
- **Aggregates** (`video_neighbors`, `video_trending`) are rebuilt from scratch
  every hour, so removed history leaves them within an hour. R5 keeps any one
  person's history from being visible through them.
- Deleting an account cascades through every per-user table.
- `rec_events` holds video ids, positions, and times, never titles or search
  text, and is pruned at 30 days.
- If *Pause history* ships (watch history, open question 2), a paused user's
  seeds come only from likes and subscriptions.

---

## 5. API

Errors are `{"detail", "code"}` as elsewhere. "Cookie" means
`Depends(get_current_user)`. "Optional" means `get_optional_identity`: no
cookie works, and a valid cookie personalises the response.

### 5.1 Category and tags

- `SaveVideoRequest` (`POST /upload/video/save`) and `UpdateVideoRequest`
  (`PATCH /video/{id}`) gain:
  - `category`: optional, one code; anything else is a 400
    `invalid_category`;
  - `tags`: optional list, normalised as in §3.1. On `PATCH`, a list replaces
    the tags and `[]` clears them.
- `VideoDetail` gains `category`, `tags`, and `likes_count`. They're added to
  the `video:meta` cache entry, which `PATCH` already invalidates.
  `likes_count` can lag the cache TTL, like `views_count`. `FeedItem` doesn't
  change, so the feed stays light.
- `GET /video/categories` (public) returns `{"items": [{"code", "label"}]}`
  from `app/categories.py`, so the app never keeps its own copy.

### 5.2 Reactions

- `PUT /video/{id}/reaction`, cookie, body `{"value": "like" | "dislike" |
  "none"}` → `200 {"value", "likes_count"}`.
  - Idempotent.
  - The caller must be able to watch the video (watch history §4, *Who may
    write*). Otherwise it's 404 `video_not_found`.
  - The row write and the `likes_count` change (the delta from old value to
    new) happen in one transaction. On PostgreSQL the old row is read with
    `FOR UPDATE`; SQLite serialises writers.
- `GET /video/{id}/reaction`, cookie → `{"value"}`. Kept separate from the
  public detail read (R12).

### 5.3 Subscriptions

- `PUT /video/channel/{user_id}/subscription` and the matching `DELETE`,
  cookie → `204`, both idempotent.
  - Subscribing to yourself is a 400 `cannot_subscribe_to_self`.
  - An unknown channel is a 404 `channel_not_found`, as `GET /video/channel`
    answers.
- `GET /video/subscriptions`, cookie → `{"items": [{"id", "name"}]}`: every
  channel the caller subscribes to, at most 1,000, newest first. The app loads
  it once per session (§7.4).
- `GET /video/subscriptions/feed?page&limit`, cookie → `FeedResponse` (§4.4).
- `ChannelResponse` gains `subscriber_count`, a count on the
  `(channel_id)` index.

### 5.4 Not interested

`POST /video/{id}/not-interested` and `DELETE /video/{id}/not-interested`
(undo), cookie → `204`, idempotent. A video the caller can't watch is a 404.

### 5.5 `GET /video/recommended` — the home feed

Optional auth. Query: `page` (default 1), `limit` (1–50, default 24), and
`rec_id` (required when `page > 1`).

```json
{
  "total": 200,
  "page": 1,
  "limit": 24,
  "rec_id": "5b0f…",
  "bucket": "treatment",
  "items": [
    { "…every FeedItem field…": "…",
      "reason": { "source": "neighbors", "text": "Because you watched Fingerstyle guitar basics" } }
  ]
}
```

- **Page 1 always builds a new list** (§4.2).
- Page > 1 with a `rec_id` that is no longer in Redis builds a new list and
  answers with the new `rec_id`. The app drops ids it already shows.
- `bucket` is `treatment` or `control` (R14). Control lists are newest-first
  with `reason: null`. Signed-out callers are always treatment, because the
  trending and fresh feed is their only change.

### 5.6 `GET /video/{id}/related` — *Up next*

Optional auth. Query: `limit` (1–40, default 20).
Response: `{"rec_id", "items": [FeedItem + reason]}`. A video the caller can't
watch is a 404 `video_not_found`.

### 5.7 `POST /video/events` — impressions and clicks

Cookie.

```json
{
  "events": [
    { "type": "impression", "video_id": "8f1c…", "surface": "home",
      "rec_id": "5b0f…", "source": "neighbors", "position": 3,
      "at": "2026-10-24T10:15:04Z" }
  ]
}
```

- 1–100 events → `204`.
- `bucket` is filled in by the server from the user, never sent by the client.
- `at` is clamped to now. Events older than a day are dropped.
- An unknown or unwatchable `video_id` is dropped silently: the call is
  fire-and-forget and has no per-entry results.
- Signed-out callers aren't recorded (open question 7). They get a 401, so the
  app doesn't send anything when signed out.

### 5.8 Summary and route order

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/video/categories` | public | Category codes and labels |
| GET | `/video/recommended` | optional | Home feed (frozen list, paged) |
| GET | `/video/subscriptions` | cookie | Channels I subscribe to |
| GET | `/video/subscriptions/feed` | cookie | Their uploads, newest first |
| POST | `/video/events` | cookie | Impressions and clicks |
| GET | `/video/{id}/related` | optional | *Up next* |
| GET / PUT | `/video/{id}/reaction` | cookie | My reaction / set it |
| POST / DELETE | `/video/{id}/not-interested` | cookie | Dismiss / undo |
| PUT / DELETE | `/video/channel/{user_id}/subscription` | cookie | Subscribe / unsubscribe |

`app/main.py` includes `engagement.router` and `recs.router` **before**
`video.router` (R7). Within them, static paths come before `/{id}` paths, as
in `video.py`.

CORS needs `PUT` added to the allowed methods in `main.py`, which today are
`GET`, `POST`, `PATCH`, and `DELETE`. Production is same-origin, so this only
matters for the cross-origin dev setup.

---

## 6. Backend changes, file by file

| File | Change |
|---|---|
| `app/categories.py` (new) | The category codes and labels (§3.1). |
| `app/models.py` | `Video.category`, `Video.likes_count`, `VideoTag`, `VideoReaction`, `Subscription`, `NotInterested`, `VideoNeighbor`, `VideoTrending`, `RecEvent`, and later `VideoEmbedding`. |
| `migrations/versions/0004`–`0007` | §3, one per milestone. Run `alembic check` against the compose PostgreSQL after each. |
| `app/schemas.py` | Tag and category validators; `category`/`tags` on save and update; `likes_count`/`category`/`tags` on `VideoDetail`; `subscriber_count` on `ChannelResponse`; `Reason`; `RecommendedItem(FeedItem)` with `reason`; `RecommendedResponse(FeedResponse)` with `rec_id` and `bucket`; `RelatedResponse`; `ReactionRequest`/`ReactionResponse`; `SubscriptionsResponse`; `EventIn`/`EventsRequest`. |
| `app/recs/sources.py` (new) | The four candidate sources (§4.2, §4.3). Each is a function of `(db, user, now)` returning `{video_id: score}`. |
| `app/recs/rank.py` (new) | Pure functions: blend, fatigue, diversity re-rank, reason. No database access, so they're unit-tested in isolation. |
| `app/recs/service.py` (new) | `home(db, user, page, limit, rec_id)`, `related(db, video, user, limit)`, the Redis frozen lists, the rollout bucket, and the newest-first fallback. |
| `app/recs/build.py` (new) | The batch steps (§4.1) as functions of `(db, now)`. |
| `app/recs/embed.py` (new, M6) | `Embedder` interface, a Bedrock implementation, and a deterministic fake for tests. |
| `app/workers/recs_builder.py` (new) | Entry point: `--once`, the advisory lock, logging, the exit code. |
| `app/routers/engagement.py` (new) | Reactions, subscriptions, *Not interested*. |
| `app/routers/recs.py` (new) | `recommended`, `related`, `subscriptions/feed`, `events`, `categories`. |
| `app/routers/upload.py`, `app/routers/video.py` | Category and tags on save and `PATCH`; the new `VideoDetail` and `ChannelResponse` fields. |
| `app/routers/history.py` | `DEL recs:home:<user_id>` on both deletes (§4.5). |
| `app/cache.py` | The new `VideoDetail` fields in `video:meta`. |
| `app/config.py` | `RECS_ENABLED`, `RECS_ROLLOUT_PERCENT`, `RECS_MIN_COWATCH_USERS`, `RECS_W_*`, `RECS_HOME_LIST_TTL_SECONDS`. |
| `app/main.py` | Include the two routers before `video.router`; add `PUT` to CORS. |
| `terraform/recs.tf` (new) | An EventBridge Scheduler schedule (`rate(1 hour)`) that runs the API task definition on the cluster with the command override; its IAM role (`ecs:RunTask`, `iam:PassRole`); the log group. In M6, `bedrock:InvokeModel` on the task role. |
| `scripts/seed_sqlite.py`, `tests/support/seed_data.py` | Tags, categories, reactions, subscriptions, and extra history (§9.1); then one `build()` run, so the tables are populated. |
| `tests/support/test.env` | `RECS_MIN_COWATCH_USERS=1`, `RECS_ROLLOUT_PERCENT=100`. |
| `../scripts/deploy_smoke_test.py` | `GET /video/recommended` through the frontend URL is JSON (proves routing); signed in, like then un-like the uploaded video; subscribe and unsubscribe. |
| `AGENTS.md`, `README.md`, `../docs/specs/api-and-db-schema-spec.md` | Route table, tables, the batch job. |

The completion poller and the transcoder don't change.

---

## 7. Web app changes

The rules in `frontend/AGENTS.md` hold throughout: browser APIs only
through `lib/platform/`, services throw only `ApiException`, routes in
`lib/app/routes.dart`, and colours and sizes from `YtColors`/`YtSizes`.

### 7.1 New and changed files

```
lib/
├── models/
│   ├── video.dart                   CHANGED  category, tags, likesCount (detail); reason (recommended)
│   ├── category.dart                NEW      Category(code, label)
│   └── rec_page.dart                NEW      RecPage extends PageResult<Video>: recId, bucket
├── services/
│   ├── video_service.dart           CHANGED  recommended(page, recId), related(id), categories(); save/update with category + tags
│   ├── engagement_service.dart      NEW      reaction get/set, subscribe/unsubscribe, subscriptions(), subscriptionsFeed(), notInterested/undo
│   ├── subscription_store.dart      NEW      set of subscribed channel ids; ValueListenable<bool> per channel
│   └── impression_tracker.dart      NEW      buffers events; flushes every 10 s and on hide (postOnExit)
├── cubits/
│   ├── feed/recommended_cubit.dart  NEW      FeedCubit that carries recId to later pages and drops repeated ids
│   ├── feed/subscriptions_cubit.dart NEW     FeedCubit over subscriptionsFeed()
│   └── reaction/reaction_cubit.dart NEW      value + likes count, optimistic, restored on error
├── app/
│   ├── routes.dart                  CHANGED  Routes.subscriptions = '/feed/subscriptions', in signedInOnly
│   ├── router.dart                  CHANGED  the Subscriptions page inside the ShellRoute
│   └── app.dart                     CHANGED  provide EngagementService, SubscriptionStore, ImpressionTracker; session wiring
├── pages/
│   ├── home_page.dart               CHANGED  "All" chip → recommended; new "Recently uploaded" chip = today's latest feed
│   ├── subscriptions_page.dart      NEW      the grid, newest first; empty state links to Home
│   ├── watch_page.dart              CHANGED  like/dislike, Subscribe in the channel row, Up next "All" → related
│   ├── channel_page.dart            CHANGED  Subscribe button and subscriber count in the header
│   ├── upload_page.dart             CHANGED  category dropdown and tag input
│   └── shell/sidebar.dart           CHANGED  "Subscriptions" entry and the subscribed channels list (signed in)
└── widgets/
    ├── edit_video_dialog.dart       CHANGED  category and tags
    ├── video_grid_card.dart         CHANGED  ⋮ menu: reason header, Not interested; impression registration
    ├── video_list_tile.dart         CHANGED  the same, for Up next and search rows
    ├── like_bar.dart                NEW      👍 count | 👎 pill (the watch page has none today)
    ├── subscribe_button.dart        NEW      Subscribe / Subscribed, reads SubscriptionStore
    ├── tag_input.dart               NEW      chips with ✕, Enter or comma adds, max 10
    └── impression_scope.dart        NEW      wraps a scrollable; reports cards ≥ 50 % visible for ≥ 1 s
```

### 7.2 Home

- The **All** chip uses `RecommendedCubit`. **Most viewed** stays.
  **Recently uploaded** is a new chip for today's newest-first feed. The
  creator chips stay. `_noteCreators` keeps reading from whichever list is
  loaded first.
- `RecommendedCubit` extends `FeedCubit`. It passes `recId` from page 1 to
  later pages, adopts a new `recId` if the server sends one, and skips ids it
  already shows. `refresh()` asks for page 1 again, which builds a new list.
- Signed out it works the same way: the server answers with trending and
  fresh.

### 7.3 Watch page

- **Like bar** under the title, beside the channel row. `ReactionCubit`
  loads `GET /video/{id}/reaction` when signed in and updates optimistically.
  Signed out, a tap opens Sign in and returns to the watch page.
- **Subscribe button** in the channel row, hidden on your own videos.
- **Up next.** The *All* pill loads `related(id)` instead of the feed. *From
  «creator»* is unchanged.
- **Older backend fallback.** If `related` or `recommended` answers 404 or
  **422** (an older backend's `GET /video/{video_id}` rejecting
  `recommended` as a UUID), the cubit falls back to today's feed for the rest
  of the page load.

### 7.4 Subscriptions

- `SubscriptionStore` loads `GET /video/subscriptions` once after sign-in and
  session restore, and clears on sign-out.
  - `SubscribeButton` and the sidebar list both listen to it.
  - Subscribing updates it optimistically, and it's restored on error.
- **Sidebar.** A *Subscriptions* entry under *Home* goes to
  `/feed/subscriptions`. When the full guide is open, a *Subscriptions*
  section lists the channels (avatar and name, the first 7, then *Show more*)
  as on YouTube. The rail shows only the entry.
- **Subscriptions page.** The home grid over `SubscriptionsCubit`. Empty
  state: "Subscribe to channels to see their latest videos here."

### 7.5 Not interested

The ⋮ button appears on hover on grid cards and list tiles. The menu shows
the reason as a disabled header, for example *Because you watched …*, then
**Not interested** (signed in only). Choosing it:

- collapses the card into a "Video removed · **Undo**" placeholder of the
  same size, as YouTube does;
- calls `POST …/not-interested`;
- *Undo* calls `DELETE` and restores the card.

The menu is only on recommendation surfaces (home All, Up next) and doesn't
appear on your own videos.

### 7.6 Upload and edit

- A **category** dropdown, labels from `GET /video/categories`, loaded once
  and cached by `VideoService`.
- **Tags** with `TagInput`: Enter or a comma turns the text into a chip, with
  the same rules as the server (§3.1). An invalid tag shows the field error
  and isn't added.
- Both are optional, so existing flows and tests keep passing.
  `edit_video_dialog.dart` gets the same two fields.

### 7.7 Impressions and clicks

- Flutter web draws to a canvas, so there's no DOM `IntersectionObserver`.
  `ImpressionScope` wraps the home grid, the Up next column, and the
  Subscriptions grid.
  - Cards register their `GlobalKey`.
  - After layout and on each scroll-idle (200 ms), the scope checks which
    cards' render boxes are at least 50 % inside the viewport. One that stays
    so for 1 s reports an impression, once per `rec_id` and video.
  - This needs no new package.
- A **click** is reported when a card is opened (the `AppLink` tap,
  middle-click included).
- `ImpressionTracker` buffers events and `POST`s them at most every 10 s. On
  page hide it sends the buffer with `Browser.postOnExit` (from the watch
  history plan). It drops events on errors and sends nothing when signed
  out.

### 7.8 Wiring (`app/app.dart`)

Create the new services next to `VideoService` and provide them. `YtpApp`
takes test doubles, as it does for the others. On `SessionAuthenticated`,
load `SubscriptionStore`. On `SessionUnauthenticated`, clear it and drop the
impression buffer. The root `listenForVisibility` subscription from watch
history also flushes `ImpressionTracker` on hide.

---

## 8. Measuring it

### 8.1 Online metrics

`scripts/recs_report.py` (read-only, prints a table) computes, for a date
range, by surface × bucket × source:

- **CTR**: clicks / impressions.
- **Watch-through**: the share of clicks followed by an engaged watch
  (§4.1 step 1) of that video within 1 h.
- **Watch minutes per active signed-in user per day**, from `watch_history`.
- **Coverage**: the share of listed videos shown at least once that day.
- **Concentration**: the share of impressions going to the top 10 creators.

### 8.2 Offline evaluation

`scripts/recs_eval.py` runs against a database snapshot:

1. Hide each user's most recent engaged watch.
2. Build the tables from the rest.
3. Measure recall@20 and MRR of the home ranker against a trending-only
   baseline.

This only means something once there are roughly 1,000 users and 500 listed
videos. Before that, expect recommendations to look like trending.

### 8.3 A/B

Start with `RECS_ROLLOUT_PERCENT=50` for two weeks. Ship when treatment beats
control on watch minutes per user without lowering coverage. Then set it to
100, and keep `RECS_ENABLED` as the kill switch.

---

## 9. Testing

### 9.1 Backend

**Seed data**:

| Video | Category | Tags |
|---|---|---|
| `mountains` | `travel` | `hiking`, `india`, `outdoors` |
| `cooking` | `howto` | `recipe`, `indian food` |
| `guitar` | `music` | `guitar`, `lesson` |
| `timelapse` | `travel` | `city`, `night`, `outdoors` |

History is added for Bob on `mountains` and `timelapse`, so that pair is
co-watched by Alice and Bob. Alice likes `guitar`, Bob subscribes to Alice,
and Bob marks `cooking` *Not interested*. `seed_sqlite.py` then runs
`build()`, and the tests set `RECS_MIN_COWATCH_USERS=1`.

**Integration tests:**

- Categories and tags:
  - save and `PATCH` with a category and tags;
  - normalisation;
  - 11 tags, a bad character, or an unknown category is a 400.
- Reactions:
  - like, then dislike, then none moves `likes_count` 0 → 1 → 0 → 0;
  - repeating a value is a no-op;
  - Bob reacting to Alice's `diary` is a 404.
- Subscriptions:
  - subscribing and unsubscribing are idempotent;
  - subscribing to yourself is a 400;
  - an unknown channel is a 404;
  - `subscriber_count`;
  - the subscriptions feed shows only listed videos, newest first.
- `GET /video/recommended`:
  - signed out: trending then fresh, no reason that needs a user;
  - Bob, signed in: no `cooking` (dismissed), none of his own videos, Alice's
    uploads with the *From Alice Tester* reason, and no `timelapse` while his
    history entry is under 3 days old;
  - paging with `rec_id` walks the list exactly once, even after Bob writes
    new history in between;
  - an expired `rec_id` returns a new one;
  - making a video PRIVATE removes it from the next page 1 before any
    rebuild;
  - `RECS_ROLLOUT_PERCENT=0` gives `bucket: control` and newest-first.
- `GET /video/{id}/related`:
  - `mountains` → `timelapse` first (co-watch and shared tags);
  - never the video itself;
  - 404 for a private video that isn't yours.
- `POST /video/events`: stored with the server's bucket; 0 or 101 events is
  a 400; an unknown video is dropped; signed out is a 401.
- Every cookie route without cookies is a 401 `missing_access_token`.
- `/video/recommended` isn't captured by `/video/{video_id}` (a route-order
  regression test).

**Sanity tests:**

- `rank.py`: the blend, the fatigue cap, the diversity constraint on a
  crafted list, and reason selection;
- `build.py`: co-watch cosine on a small matrix, the R5 threshold, the
  content score, and the trending decay;
- a build twice in a row gives identical tables.

### 9.2 Web app

VM tests with the existing tools:

- `RecommendedCubit`: passes `recId` on, adopts a new one, drops repeated
  ids, falls back on 404 or 422.
- `ReactionCubit`: optimistic toggling and restore on error.
- `SubscriptionStore`: load, optimistic update, cleared on sign-out.
- `TagInput`: the normalisation rules.
- `ImpressionScope`, with `fake_async` and a scripted scroll: a card visible
  for 1 s reports once; a card scrolled past in 0.5 s doesn't.
- `ImpressionTracker`: batching, the 10 s cadence, `postOnExit` on hide,
  nothing when signed out.
- Widget tests:
  - the like bar;
  - Subscribe on the watch and channel pages;
  - the sidebar Subscriptions section;
  - the Subscriptions page (list and empty);
  - Not interested with Undo;
  - the upload form with category and tags;
  - the home All chip using `recommended`.

### 9.3 Browser E2E

Extend `integration_test/seeded_flow_test.dart`. As Bob:

1. Home shows the seeded recommended order.
2. Not interested on a card, then Undo.
3. Open `mountains` and see `timelapse` first in Up next.
4. Like it.
5. Subscribe to Alice from her channel page, and see her in the sidebar.
6. Open Subscriptions.

### 9.4 Manual check on a deployed stack

With three accounts, watch overlapping videos and run the job by hand
(`aws ecs run-task` with the schedule's command override). Related
lists should reflect the overlap. Then clear one account's history, and that
account's home should stop showing *Because you watched …*.

---

## 10. Rollout and milestones

The backend ships first in every step, and each step is additive.

| Step | Scope | Done when |
|---|---|---|
| **M1** Metadata | `0004`, categories, tags on save, `PATCH` and detail, `GET /video/categories`, upload and edit UI, seed tags | Tests green; a new upload has a category and tags |
| **M2** Engagement | `0005`, reactions and `likes_count`, subscriptions with the feed, page and sidebar, *Not interested*, like bar, Subscribe button | Tests and E2E steps 2, 4, 5, 6 green |
| **M3** Batch job + related | `0006`, `build.py`, `recs_builder`, `terraform/recs.tf`, `GET /video/{id}/related`, Up next switch | The job runs hourly in the deployed stack; Up next shows related videos; E2E step 3 green. *Needs watch history M1–M3.* |
| **M4** Home recommendations | `GET /video/recommended`, frozen lists, flag and bucket, `RecommendedCubit`, home chips, the 404/422 fallback | Tests green; `RECS_ROLLOUT_PERCENT=0` in prod at first |
| **M5** Measurement | `POST /video/events`, `ImpressionScope`, `ImpressionTracker`, fatigue on, `recs_report.py` | Events arrive from the deployed app; report runs |
| **M6** Embeddings | `0007`, `embed.py`, Bedrock IAM, content score blend | Related lists improve on videos with few or no tags (eyeballed, then `recs_eval.py`) |
| **M7** A/B and tune | Rollout 50 %, two weeks, §8.3 decision, `recs_eval.py` | Decision recorded; rollout at 100 % or rolled back |

M1 and M2 don't depend on watch history and can run in parallel with it.

---

## 11. Risks and open questions

### Risks

- **Cognito `GetUser` per request.** Today the feed takes no auth, so
  browsing costs no Cognito calls. `recommended` and `related` resolve the
  caller when a cookie is present, and events add one call per 10 s per
  active tab. This is the same pressure watch history §10 describes, and it
  has the same fix: verify the access-token JWT locally against the pool's
  JWKS. Do that before M4 reaches 100 %.
- **Small catalogue.** With tens of videos, recommendations will look like
  trending with a few personal touches. That's expected, and the fresh slot
  and fatigue keep the feed from going stale.
- **Popularity loop.** Trending feeds impressions, which feed trending.
  Mitigations: the fresh slot (R10), fatigue, and the coverage metric (§8.1)
  to catch it.
- **Tag stuffing.** Capped at 10 tags, and tags carry at most 60 % of a
  content score. Embeddings (M6) rely less on what uploaders type.
- **Batch job growth.** Python aggregation is fine to about 10 M history rows
  (§4.1). Watch the job's duration metric, and move step 2 to SQL or Athena
  before it nears the hour.
- **`rec_events` volume.** Fine on RDS for v1 (§3.5). Past a few hundred
  million rows, write events to Firehose → S3 and run §8.1 in Athena.
- **Redis outage.** Lists are rebuilt per page and the app removes
  duplicates. It's slower but correct, and the empty-tables fallback covers
  the first deploy.
- **Cost.** The hourly task (0.25 vCPU, a few minutes) costs a few dollars a
  month. Redis and RDS already exist. Bedrock embeddings (M6) are charged per
  token and only for new or changed videos.

### Open questions

1. **Signed-out views in trending?** That needs view dedupe, for example a
   Redis key per (IP hash, video, day) on `POST /video/{id}/view`. Worth it,
   and it would fix `views_count` too.
2. **Show the reason on the card**, not only in the ⋮ menu?
3. **Don't recommend channel**: a second dismissal type.
4. **Continue watching**: include partly watched videos on Home (this plan
   drops them for 3 days), or add a separate row?
5. **Notifications** for new uploads from subscriptions: a bell and an
   unread count.
6. **Category list**: YouTube's 15, or a shorter list that suits this app?
7. **Anonymous impressions**: needs an anonymous id cookie, and with it a
   consent decision.
8. **Embedding provider**: check Bedrock model availability and price in
   `ap-south-1`, or run a small open model in the batch task.
9. **Dislike counts**: hidden, as on YouTube today, or shown to the owner on
   Your videos?
10. **Mockup**: the like bar, Subscribe button, sidebar Subscriptions section
    and ⋮ menu should follow the Figma file the app's look comes from. The
    Figma MCP couldn't connect when this plan was written, so §7 follows
    YouTube's current desktop UI.
