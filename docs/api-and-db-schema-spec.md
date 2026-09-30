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
| `refresh_token` | `HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/auth/refresh` | Encrypted refresh token for renewing expired sessions |

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
Retrieves a paginated list of publicly available, fully processed videos for the mobile application home feed.

* **HTTP Method**: `GET`
* **Path**: `/video/feed`
* **Authentication**: Optional
* **Query Parameters**:
  * `page` (Integer, Default: `1`): Page index.
  * `limit` (Integer, Default: `10`, Max: `50`): Number of items per page.

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
| `manifest_url` | String (URL) | CloudFront CDN URL for MPEG-DASH streaming manifest (`.mpd`) |
| `views_count` | Integer | Total accumulated view count |
| `duration_seconds` | Integer | Total playback duration in seconds |
| `creator` | Object | Creator details (`id`, `name`) |
| `created_at` | String (ISO 8601) | Upload timestamp |

---

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

#### C. Relational Model Summary
* **`users` to `videos`**: One-to-Many Relationship. One user can upload multiple videos (`1:N`). Deleting a user cascade-deletes all associated video metadata records.

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
  * `thumbnail_url`: Full CloudFront CDN URL for thumbnail image.
  * `manifest_url`: Full CloudFront CDN URL for DASH master manifest file.
  * `creator_name`: Display name of video creator.
  * `status`: Current video status string (`COMPLETED`).
  * `views_count`: Cached view count string integer.

##### Key 2: User Session Token Blacklist (Optional Security Layer)
* **Key Format**: `session:blacklist:{access_token_id}`
* **Data Structure**: `String`
* **TTL / Expiration Policy**: Matches remaining token lifetime.
* **Value**: `revoked`
