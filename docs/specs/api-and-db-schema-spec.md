# Video Streaming Platform - API & Database Schema Specification

This document provides a comprehensive technical specification for all application programming interfaces (APIs) and database schemas used across the video streaming platform. It serves as the definitive reference for frontend engineers (Flutter client), backend engineers (FastAPI gateway), and infrastructure developers without embedding raw programming language implementations.

---

## 1. Authentication & User Management APIs (`/auth`)

### 1.1 User Registration (`POST /auth/signup`)
Registers a new user account in AWS Cognito and creates a mirrored profile record in the relational database.

* **HTTP Method**: `POST`
* **Path**: `/auth/signup`
* **Authentication**: None (Public Endpoint)
* **Headers**: `Content-Type: application/json`

#### Request Body Schema
| Field | Type | Required | Validation Rules | Description |
| :--- | :--- | :--- | :--- | :--- |
| `name` | String | Yes | Non-empty, 2–50 characters | Full display name of the user |
| `email` | String | Yes | Valid email format | User's email address (used as username) |
| `password` | String | Yes | Min 8 chars, 1 uppercase, 1 number, 1 special char | Account password |

#### Response Body Schema (200 OK)
| Field | Type | Description |
| :--- | :--- | :--- |
| `message` | String | Confirmation message directing user to check email for OTP |

#### Error Responses
* `400 Bad Request`: Email already registered, weak password, or invalid parameter format.
* `500 Internal Server Error`: Cloud identity provider or database synchronization failure.

---

### 1.2 OTP Email Verification (`POST /auth/verify-otp`)
Confirms the user's registered email address by validating the one-time passcode (OTP) issued by AWS Cognito.

* **HTTP Method**: `POST`
* **Path**: `/auth/verify-otp`
* **Authentication**: None (Public Endpoint)
* **Headers**: `Content-Type: application/json`

#### Request Body Schema
| Field | Type | Required | Validation Rules | Description |
| :--- | :--- | :--- | :--- | :--- |
| `email` | String | Yes | Valid email format | Registered user email |
| `otp` | String | Yes | 6-digit numeric string | One-time password sent via email |

#### Response Body Schema (200 OK)
| Field | Type | Description |
| :--- | :--- | :--- |
| `message` | String | Confirmation that account verification was successful |

#### Error Responses
* `400 Bad Request`: Invalid or expired OTP code.
* `404 Not Found`: Email user not found in identity registry.

---

### 1.3 User Login (`POST /auth/login`)
Authenticates user credentials against AWS Cognito and sets secure, encrypted session tokens in HTTP cookies.

* **HTTP Method**: `POST`
* **Path**: `/auth/login`
* **Authentication**: None (Public Endpoint)
* **Headers**: `Content-Type: application/json`

#### Request Body Schema
| Field | Type | Required | Validation Rules | Description |
| :--- | :--- | :--- | :--- | :--- |
| `email` | String | Yes | Valid email format | Registered user email |
| `password` | String | Yes | Non-empty string | Account password |

#### Response Cookies (`Set-Cookie` Headers)
| Cookie Name | Attributes | Description |
| :--- | :--- | :--- |
| `access_token` | `HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/` | Encrypted JWT access token issued by identity provider |
| `refresh_token` | `HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/auth` | Encrypted refresh token for renewing expired sessions (sent to `/auth/refresh` and `/auth/logout`) |

#### Response Body Schema (200 OK)
| Field | Type | Description |
| :--- | :--- | :--- |
| `message` | String | Success confirmation message |

#### Error Responses
* `400 Bad Request`: Incorrect password or unconfirmed user email.
* `404 Not Found`: Account does not exist.

---

### 1.4 Get Current User Profile (`GET /auth/me`)
Retrieves profile details for the currently authenticated user session. Used on application launch for silent session restoration.

* **HTTP Method**: `GET`
* **Path**: `/auth/me`
* **Authentication**: Required (`access_token` HTTP Cookie)
* **Headers**: None

#### Response Body Schema (200 OK)
| Field | Type | Description |
| :--- | :--- | :--- |
| `id` | String (UUID) | Internal database primary key ID |
| `name` | String | Display name of the user |
| `email` | String | Registered email address |
| `cognito_sub` | String (UUID) | AWS Cognito unique subject identifier |
| `created_at` | String (ISO 8601) | Account creation timestamp |

#### Error Responses
* `401 Unauthorized`: Missing, expired, or invalid session cookie.

---

### 1.5 Session Token Refresh (`POST /auth/refresh`)
Exchanges an existing valid refresh token cookie for a new access token cookie without requiring re-authentication.

* **HTTP Method**: `POST`
* **Path**: `/auth/refresh`
* **Authentication**: Required (`refresh_token` HTTP Cookie)
* **Headers**: None

#### Response Cookies (`Set-Cookie` Headers)
| Cookie Name | Attributes | Description |
| :--- | :--- | :--- |
| `access_token` | `HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/` | New active access token |

#### Response Body Schema (200 OK)
| Field | Type | Description |
| :--- | :--- | :--- |
| `message` | String | Confirmation that token refresh succeeded |

#### Error Responses
* `401 Unauthorized`: Expired or revoked refresh token.

---

## 2. Video Upload & Storage APIs (`/upload/video`)

### 2.1 Get Presigned Video Upload URL (`GET /upload/video/url`)
Generates a temporary pre-signed S3 `PUT` URL allowing the client to upload a raw video file directly to cloud storage.

* **HTTP Method**: `GET`
* **Path**: `/upload/video/url`
* **Authentication**: Required (`access_token` HTTP Cookie)

#### Response Body Schema (200 OK)
| Field | Type | Description |
| :--- | :--- | :--- |
| `url` | String (URL) | Temporary pre-signed S3 PUT URL for raw video upload |
| `video_id` | String | S3 Key coordinate formatted as `videos/{user_sub}/{uuid}.mp4` |

---

### 2.2 Get Presigned Thumbnail Upload URL (`GET /upload/video/url/thumbnail`)
Generates a temporary pre-signed S3 `PUT` URL for direct upload of a custom thumbnail image.

* **HTTP Method**: `GET`
* **Path**: `/upload/video/url/thumbnail`
* **Authentication**: Required (`access_token` HTTP Cookie)

#### Response Body Schema (200 OK)
| Field | Type | Description |
| :--- | :--- | :--- |
| `url` | String (URL) | Temporary pre-signed S3 PUT URL for thumbnail upload |
| `thumbnail_id` | String | S3 Key coordinate formatted as `thumbnails/{user_sub}/{uuid}` |

---

### 2.3 Save Video Metadata (`POST /upload/video/save`)
Records uploaded video metadata into the database and sets initial processing state to `PENDING`.

* **HTTP Method**: `POST`
* **Path**: `/upload/video/save`
* **Authentication**: Required (`access_token` HTTP Cookie)
* **Headers**: `Content-Type: application/json`

#### Request Body Schema
| Field | Type | Required | Validation Rules | Description |
| :--- | :--- | :--- | :--- | :--- |
| `title` | String | Yes | Non-empty, max 100 chars | Title of the video |
| `description` | String | No | Max 1000 chars | Video description |
| `s3_key` | String | Yes | Valid raw S3 key string | Object key obtained from presigned URL endpoint |
| `thumbnail_s3_key` | String | Yes | Valid thumbnail key string | Thumbnail object key obtained from URL endpoint |
| `visibility` | String (Enum) | Yes | `PUBLIC`, `PRIVATE`, `UNLISTED` | Target access level |

#### Response Body Schema (201 Created)
| Field | Type | Description |
| :--- | :--- | :--- |
| `id` | String (UUID) | Newly generated video database ID |
| `title` | String | Title of the video |
| `status` | String (Enum) | Initial processing state (`PENDING`) |
| `visibility` | String (Enum) | Access visibility setting |
| `created_at` | String (ISO 8601) | Record creation timestamp |

---

## 3. Video Playback & Feed APIs (`/video`)

### 3.1 Get Home Video Feed (`GET /video/feed`)
Retrieves a paginated list of publicly available, fully processed videos for the web app's home feed.

* **HTTP Method**: `GET`
* **Path**: `/video/feed`
* **Authentication**: Optional
* **Query Parameters**:
  * `page` (Integer, Default: `1`): Page index.
  * `limit` (Integer, Default: `10`, Max: `50`): Number of items per page.
  * `sort` (String, Default: `latest`): `latest` (newest first) or `popular` (most viewed first).

#### Response Body Schema (200 OK)
| Field | Type | Description |
| :--- | :--- | :--- |
| `total` | Integer | Total count of eligible public videos |
| `page` | Integer | Current page index |
| `limit` | Integer | Number of items per response |
| `items` | Array of Objects | List of video summary items (schema detailed below) |

#### Feed Item Object Schema
| Field | Type | Description |
| :--- | :--- | :--- |
| `id` | String (UUID) | Unique video identifier |
| `title` | String | Title of the video |
| `description` | String | Short video description |
| `thumbnail_url` | String (URL) | CloudFront CDN URL for thumbnail rendering |
| `manifest_url` | String (URL) | MPEG-DASH manifest (`.mpd`), `/media/<key>` relative to the API's origin; streamable after `POST /video/{video_id}/playback` (§3.2a) |
| `hls_url` | String (URL) | HLS master playlist over the same segments, same form; null for videos transcoded before HLS output |
| `views_count` | Integer | Total accumulated view count |
| `duration_seconds` | Integer | Total playback duration in seconds |
| `creator` | Object | Creator details (`id`, `name`) |
| `created_at` | String (ISO 8601) | Upload timestamp |

---

### 3.1a Search Videos (`GET /video/search`)
Public, fully processed videos whose title or description contains every word of the query (case-insensitive).

* **HTTP Method**: `GET`
* **Path**: `/video/search`
* **Authentication**: None
* **Query Parameters**: `q` (String, 1–100 characters, required), plus `page`, `limit`, and `sort` as for the feed.
* **Response**: same shape as the feed. A query of only spaces is `400` with code `empty_query`.

### 3.1b Channel (`GET /video/channel/{user_id}`)
A creator and their public, fully processed videos. Private, unlisted, and unfinished videos are never listed here, whoever asks.

* **HTTP Method**: `GET`
* **Path**: `/video/channel/{user_id}`
* **Authentication**: None
* **Query Parameters**: `page`, `limit`, and `sort` as for the feed.
* **Response**: the feed's shape plus `creator` (`id`, `name`, `created_at`). Unknown user: `404` with code `channel_not_found`.

### 3.2 Get Video Details by ID (`GET /video/{video_id}`)
Fetches detailed metadata and streaming manifest URLs for a single video.

* **HTTP Method**: `GET`
* **Path**: `/video/{video_id}`
* **Authentication**: Optional (Required for `PRIVATE` videos owned by requester)
* **Path Parameters**:
  * `video_id` (UUID): Primary key ID of the target video.

#### Response Body Schema (200 OK)
Returns the complete Feed Item Object Schema along with full creator details and status flags.

---

### 3.2a Authorize Playback (`POST /video/{video_id}/playback`)
Lets the caller's browser stream the video for a while. The stream URLs are served by the edge CloudFront distribution under `/media/`, which refuses every request without CloudFront signed cookies; this endpoint sets them, for the folder holding the video's manifests and segments only.

* **HTTP Method**: `POST`
* **Path**: `/video/{video_id}/playback`
* **Authentication**: Optional, as for `GET /video/{video_id}`: anyone may stream a `PUBLIC` or `UNLISTED` video, only the owner a `PRIVATE` one

#### Response Cookies (`Set-Cookie` Headers)
* `CloudFront-Policy`, `CloudFront-Signature`, `CloudFront-Key-Pair-Id`: `HttpOnly; Secure; SameSite=Lax; Path=/media/<folder>/; Max-Age=3600` (the TTL is `MEDIA_COOKIE_TTL_SECONDS`). The policy's resource is `https://*/<folder>/*` and it expires with the cookies.

#### Response Body Schema (200 OK)
| Field | Type | Description |
| :--- | :--- | :--- |
| `expires_at` | ISO-8601 (UTC), nullable | When the cookies stop working; clients renew a few minutes before. Null when the API has no signing key (local runs) |

The response carries `Cache-Control: no-store`.

#### Error Responses
* `404 video_not_found`: no such video, or the caller may not read it.
* `409 video_not_ready`: not `COMPLETED` yet.

---

### 3.3 Watch History (`/history`)
Per-user progress on each video, synced across browsers. Every route requires the `access_token` cookie (`401 missing_access_token` without it). The design and the sync rules are in `docs/plans/watch-history-plan.md`.

| Method | Path | Purpose |
| :--- | :--- | :--- |
| `POST` | `/history/progress` | Record a batch of 1–50 progress reports |
| `GET` | `/history` | The caller's history, most recently watched first (`limit` 1–50, default 20; opaque `cursor`) |
| `GET` | `/history/positions` | The caller's progress on up to 50 videos (`video_ids`, comma-separated); videos with no entry are left out |
| `DELETE` | `/history/{video_id}` | Remove one entry (`204`, also when there was none) |
| `DELETE` | `/history` | Clear all of the caller's history (`204`) |

#### Progress Report (`POST /history/progress` entries)
| Field | Type | Required | Validation Rules | Description |
| :--- | :--- | :--- | :--- | :--- |
| `video_id` | UUID | Yes | | Video watched |
| `position_seconds` | Integer | Yes | 0–86,400 | Position reached |
| `duration_seconds` | Integer | No | 1–86,400 | Duration the player reported; the server's own duration wins when it has one |
| `watched_at` | ISO-8601 | Yes | Must carry a timezone offset | When the browser observed the position |

The server keeps, per (user, video), the report with the latest `watched_at` (clamped to the server clock), so a report that arrives late never overwrites newer progress from another browser. A video is `completed` at 95 % or with 10 s or less left.

Each entry gets one result (`results`, one per distinct `video_id`, in request order): `saved`; `stale` (the server holds a newer observation, returned in `progress`); `not_found` (no such video, or the caller can't watch it); `expired` (`watched_at` more than 30 days old). One bad entry never fails the batch.

#### Watch Progress Object Schema
| Field | Type | Description |
| :--- | :--- | :--- |
| `video_id` | UUID | Video |
| `position_seconds` | Integer | Last position, clamped to the duration |
| `duration_seconds` | Integer (nullable) | Duration used for the completion rule |
| `completed` | Boolean | Watched to the end |
| `last_watched_at` | ISO-8601 (UTC) | Observation time of the stored progress |

`GET /history` returns `{"items": [{"video": <Feed Item>, "progress": <Watch Progress>}], "next_cursor": <string or null>}`. Only videos the caller can watch now are listed; rows for videos made private are kept and come back if the video does. A malformed `cursor` is `400 history_cursor_invalid`.

---

## 4. Internal Processing Webhook API (`/webhook`)

### 4.1 Transcoding Complete Callback (`POST /webhook/transcode-complete`)
Internal callback triggered by transcoder worker containers upon successful completion of MPEG-DASH video conversion.

* **HTTP Method**: `POST`
* **Path**: `/webhook/transcode-complete`
* **Authentication**: Required (`X-Internal-Secret` Header)
* **Headers**: `Content-Type: application/json`

#### Request Body Schema
| Field | Type | Required | Description |
| :--- | :--- | :--- | :--- |
| `raw_s3_key` | String | Yes | Original raw video object key |
| `dash_manifest_s3_key` | String | Yes | S3 key for generated `.mpd` master manifest |
| `status` | String (Enum) | Yes | `COMPLETED` or `FAILED` |
| `duration_seconds` | Integer | No | Extracted total video length |

#### Response Body Schema (200 OK)
| Field | Type | Description |
| :--- | :--- | :--- |
| `message` | String | Database status update confirmation |

---

## 5. Database Schemas Specification

### 5.1 Relational Database Schema (PostgreSQL)

#### A. Custom Enumerated Types (Enums)

##### `VisibilityEnum`
Defines video access control settings.
* `PUBLIC`: Visible in global feed and creator profiles.
* `PRIVATE`: Visible only to the content creator.
* `UNLISTED`: Accessible only via direct URL lookup.

##### `StatusEnum`
Tracks the processing lifecycle of an uploaded video.
* `PENDING`: Metadata saved, raw file uploaded, waiting for processing.
* `PROCESSING`: Ephemeral transcoder worker actively converting video formats.
* `COMPLETED`: Transcoding finished; DASH manifest and chunks available on CDN.
* `FAILED`: Transcoding container encountered an unrecoverable error.

---

#### B. Entity Relationship Table Specs

##### Table 1: `users`
Stores user profile information synced from the identity provider.

| Field Name | Data Type | Nullable | Primary Key | Foreign Key | Index | Constraints / Default | Description |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `id` | UUID | No | Yes | No | Yes | Auto-generated UUIDv4 | System primary key |
| `name` | VARCHAR(100) | No | No | No | No | None | Display name |
| `email` | VARCHAR(255) | No | No | No | Unique | Unique format | Registered email address |
| `cognito_sub` | VARCHAR(255) | No | No | No | Unique | Unique format | Identity provider subject ID |
| `created_at` | TIMESTAMP | No | No | No | No | `CURRENT_TIMESTAMP` | Profile creation time |
| `updated_at` | TIMESTAMP | No | No | No | No | `CURRENT_TIMESTAMP` | Last profile update time |

---

##### Table 2: `videos`
Stores metadata, processing states, and storage coordinates for video content.

| Field Name | Data Type | Nullable | Primary Key | Foreign Key | Index | Constraints / Default | Description |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `id` | UUID | No | Yes | No | Yes | Auto-generated UUIDv4 | System primary key |
| `title` | VARCHAR(150) | No | No | No | Yes | None | Video title |
| `description` | TEXT | Yes | No | No | No | None | Full description text |
| `s3_key` | VARCHAR(500) | No | No | No | Unique | Unique format | S3 Key of raw uploaded file |
| `thumbnail_s3_key` | VARCHAR(500) | No | No | No | No | None | S3 Key of thumbnail image |
| `dash_manifest_s3_key` | VARCHAR(500) | Yes | No | No | No | Default `NULL` | S3 Key of transcoded `.mpd` file |
| `visibility` | `VisibilityEnum`| No | No | No | Yes | Default `PUBLIC` | Visibility access setting |
| `status` | `StatusEnum` | No | No | No | Yes | Default `PENDING` | Pipeline processing status |
| `user_id` | UUID | No | No | `users.id` | Yes | `ON DELETE CASCADE` | Creator foreign key reference |
| `views_count` | BIGINT | No | No | No | No | Default `0` | View counter |
| `duration_seconds` | INTEGER | Yes | No | No | No | Default `NULL` | Video length in seconds |
| `created_at` | TIMESTAMP | No | No | No | Yes | `CURRENT_TIMESTAMP` | Record creation timestamp |
| `updated_at` | TIMESTAMP | No | No | No | No | `CURRENT_TIMESTAMP` | Last record modification time |

---

##### Table 3: `watch_history`
One row per (user, video): the latest progress the user reached. Written only by the `/history` routes.

| Field Name | Data Type | Nullable | Primary Key | Foreign Key | Index | Constraints / Default | Description |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `user_id` | UUID | No | Yes | `users.id` | Yes | `ON DELETE CASCADE` | Viewer |
| `video_id` | UUID | No | Yes | `videos.id` | Yes | `ON DELETE CASCADE` | Video watched |
| `position_seconds` | INTEGER | No | No | No | No | `>= 0` | Last position reached |
| `duration_seconds` | INTEGER | Yes | No | No | No | Default `NULL` | Duration used for the completion rule |
| `completed` | BOOLEAN | No | No | No | No | Default `false` | Derived by the server |
| `first_watched_at` | TIMESTAMPTZ | No | No | No | No | `CURRENT_TIMESTAMP` | First report |
| `last_watched_at` | TIMESTAMPTZ | No | No | No | Yes | None | Observation time of the stored progress (UTC); orders the history |
| `updated_at` | TIMESTAMPTZ | No | No | No | No | `CURRENT_TIMESTAMP` | Server write time |

Indexes: primary key `(user_id, video_id)`; `(user_id, last_watched_at DESC, video_id DESC)` for the history list and its cursor; `(video_id)` for the cascade.

---

#### C. Relational Model Summary
* **`users` to `videos`**: One-to-Many Relationship. One user can upload multiple videos (`1:N`). Deleting a user cascade-deletes all associated video metadata records.
* **`watch_history`**: Many-to-Many between `users` and `videos`, one row per pair. Deleting either side cascade-deletes its rows.

---

### 5.2 In-Memory Caching Schema (Redis)

Redis is deployed as an in-memory caching layer to eliminate redundant relational database queries for high-frequency video metadata requests.

#### Key Structure & Schema Specifications

##### Key 1: Video Metadata Cache
* **Key Format**: `video:meta:{video_id}`
* **Data Structure**: `Hash`
* **TTL / Expiration Policy**: `3600 seconds` (1 Hour, LRU Eviction)
* **Fields**:
  * `id`: Video UUID string.
  * `title`: Video title string.
  * `description`: Video description string.
  * `thumbnail_key`, `manifest_key`, `hls_key`: the S3 keys. The URLs are built from them on read, so a change of CDN or media base applies to cached videos at once.
  * `creator_name`: Display name of video creator.
  * `status`: Current video status string (`COMPLETED`).
  * `views_count`: Cached view count string integer.

##### Key 2: User Session Token Blacklist (Optional Security Layer)
* **Key Format**: `session:blacklist:{access_token_id}`
* **Data Structure**: `String`
* **TTL / Expiration Policy**: Matches remaining token lifetime.
* **Value**: `revoked`
