# Flutter Frontend — Implementation Plan

This plan covers the Flutter client for the video platform: what to build,
how it talks to the backend in `../backend/`, and in what order. The screens
come from `../docs/frontend-screens-spec.md`. The Flutter snippets in
`../docs/auth-implementation-guide.md` and
`../docs/s3-upload-and-metadata-guide.md` are useful background.

Where those documents disagree with the backend as built, this plan follows
the backend code (`backend/app/`). §3 lists every difference, so the spec's
snippets can't be copied as they are.

Status: not started. Nothing here has run on a device yet. The spikes in M0
(§13) confirm the riskier assumptions before any later phase depends on them.

The backend and pipeline gaps this plan first identified (B1–B8 in §14) have
been closed: HLS output for iOS, resend and password-reset endpoints, error
codes, late-save handling, edit and delete, view counting, and a ladder that
keeps portrait video portrait. The plan below assumes all of them. Only B9,
which the deferred web target needs, is still open.

---

## Contents

1. Scope
2. Key decisions
3. Where the spec and the backend differ
4. Backend contract
5. Architecture
6. Screens
7. Upload pipeline
8. Playback
9. Security
10. Platform setup
11. Local development
12. Testing
13. Milestones
14. Backend and pipeline dependencies
15. Risks and open questions

---

## 1. Scope

**In scope for v1**

- Android and iOS phones.
- The six screens in the spec: Sign Up, Confirm Sign Up, Sign In, Home Feed,
  Upload, and Video Player.
- A launch gate (splash) that restores the session.
- A **My Videos** screen. The spec doesn't have one, but the backend
  supports it (`GET /video/mine`) and the upload flow needs it. A new upload
  doesn't appear in the home feed until it has finished processing, and never
  appears there if it isn't PUBLIC. Without My Videos, users have no way to
  see their upload's progress, or to find their private and unlisted videos.
- Logout. The spec has no control for it.
- **Resend code** on Confirm Sign Up, and a **Forgot password** flow (two
  screens: Forgot Password and Reset Password). The spec has neither, but a
  user with a lost or expired code, or a forgotten password, is otherwise
  locked out.
- **Edit and delete** for the owner's videos: title, description, and
  visibility, from My Videos and from the player.
- A view count on cards and in the player, incremented when playback starts.

**Out of scope for v1**

- Flutter web. It needs a different auth transport (cookies managed by the
  browser), a JavaScript DASH player, and changes to the backend's CORS and
  SameSite settings. B9 in §14 lists what a web phase would need.
- Tablet and desktop layouts, offline viewing, and push notifications.
- Comments, likes, search, and channel pages. The backend has no endpoints
  for them.

---

## 2. Key decisions

| # | Decision | Choice | Why |
|---|---|---|---|
| D1 | Where the app lives | `frontend/` at the repo root, next to `backend/` and `IAC/` | API contract changes land in the same commit as the client change |
| D2 | Targets | Android and iOS | The spec describes a mobile app. Web is deferred (§1) |
| D3 | State management | `flutter_bloc` Cubits, as in the spec. `SessionCubit` owns the signed-in state at the root; `AuthCubit` keeps the form actions | If one cubit carries both form errors and session state, the root widget reacts to form errors |
| D4 | HTTP client | `dio` | It returns `Set-Cookie` as a list, where `package:http` joins repeated headers with commas. It also gives upload progress, cancel tokens, and a queued interceptor for a single refresh at a time |
| D5 | How the access token is sent | `Authorization: Bearer <token>` | `deps.py` accepts it as a fallback for clients without cookies, so the app needs no cookie jar |
| D6 | How the refresh token is sent | `Cookie: refresh_token=<value>`, sent only to `/auth/refresh` and `/auth/logout` | The backend reads the refresh token only from that cookie |
| D7 | Token storage | `flutter_secure_storage` (Keychain on iOS, Keystore-backed on Android) | As in the spec |
| D8 | Session length | Follow the cookies' `Max-Age`: 1 h for the access token and 5 days for the refresh token | This is the lifetime the backend intends. Cognito would accept the refresh token for 30 days, but a browser would drop it after 5 |
| D9 | Player | `better_player_plus` | A maintained fork of `better_player` with the same API. The original package has had no release since 2022 |
| D10 | iOS playback | Play `hls_url` on iOS and `manifest_url` (DASH) on Android | AVPlayer, which iOS players are built on, can't play MPEG-DASH. The pipeline writes an HLS playlist over the same segments (B1) |
| D11 | Navigation | Navigator 1.0 with a static `route()` on each page, plus a root `BlocBuilder`, as in the spec | Seven screens and no deep links in v1 |
| D12 | Models | Hand-written immutable classes with `fromJson` | About eight small types, so code generation (`build_runner`) isn't worth it |
| D13 | Feed state | A `FeedCubit` with pagination, instead of the spec's `FutureBuilder` | The feed is paginated (`page`, `limit` ≤ 50). A `FutureBuilder` can't append pages or support pull-to-refresh cleanly |
| D14 | Upload order | The spec's order: presigned URLs, then the thumbnail PUT, then the video PUT, then an immediate save | This is the flow the backend documents. A save that lands late is still applied (§7.4) |
| D15 | Configuration | `--dart-define-from-file` with `API_BASE_URL` | The API URL is the only value that changes per deployment. CDN URLs arrive in API responses |
| D16 | Error handling | Branch on the `code` field of error bodies, never on the `detail` text | `code` is a stable contract (B4); `detail` is wording for people and may change |
| D17 | Player shape | Size the player to the video's own aspect ratio, 16:9 until it is known | The ladder keeps portrait video portrait (B8), so a fixed 16:9 box would shrink phone recordings to a narrow pillarboxed strip |
| D18 | View counting | One `POST /video/{id}/view` per player page, when playback first starts | The backend counts every call with no per-viewer dedupe, so the app decides what a view is |

---

## 3. Where the spec and the backend differ

In every row the backend's behaviour wins, and the app is built to match it.

| # | Topic | Spec or guide says | Backend does | The app does |
|---|---|---|---|---|
| 1 | OTP endpoint | `POST /auth/confirm-signup` | `POST /auth/verify-otp` | `/auth/verify-otp` |
| 2 | OTP body | `otp` (screens spec), `otp_code` (auth guide) | `{"email", "otp"}`; `otp` must be exactly 6 digits | `{"email", "otp"}` |
| 3 | Signup success code | 201 (auth guide snippet) | 200 | Treats any 2xx as success |
| 4 | Password rules | At least 8 characters, 1 uppercase, 1 number, 1 special | Also needs a lowercase letter (the Cognito pool requires it); at most 256 characters | Checks all five rules before sending |
| 5 | Name | Required | 2–50 characters after trimming | Same rule on the client |
| 6 | Session hydration | Store `user_cognito_sub` in secure storage | `/auth/me` returns `{id, name, email, cognito_sub, created_at}` | Keeps the profile in `SessionCubit` and doesn't persist the sub. Ownership comes from `/video/mine`, or from `creator.id == me.id` |
| 7 | Feed endpoint | `GET /video/all`; the client filters out unfinished and private videos | `GET /video/feed?page&limit` returns `{total, page, limit, items}` and already holds only PUBLIC + COMPLETED videos | Paginates and doesn't filter |
| 8 | Status field | `is_processing` | `status`, one of `PENDING`, `PROCESSING`, `COMPLETED`, `FAILED`. Only detail and My Videos items carry it | Enum parsed from `status` |
| 9 | Thumbnail presign | `?thumbnail_id=...` in the query | Takes no parameters; the server mints the key and returns `{url, thumbnail_id}` | Sends no parameters |
| 10 | Thumbnail PUT | `Content-Type: image/jpg` and `x-amz-acl: public-read` | URL presigned for `Content-Type: image/jpeg`; the bucket blocks public ACLs | Sends exactly `image/jpeg` with no ACL header, and re-encodes the picked image to JPEG |
| 11 | Save endpoint | `POST /upload/video/metadata` | `POST /upload/video/save`, returns 201 | `/upload/video/save` |
| 12 | Save body | `video_id` + `video_s3_key` (screens spec); `video_id` + `thumbnail_id` (upload guide) | `title`, `description` (optional), `visibility`, `s3_key`, `thumbnail_s3_key`; the last two are required | The backend's body (§4.1) |
| 13 | Save response | Expects 200 (upload guide) | 201 `{id, title, status, visibility, created_at}`; 409 if the upload was already saved | Keeps `id` for progress polling, and treats 409 as already saved |
| 14 | Visibility values | `public`, `private`, `unlisted` | Case-insensitive on input, uppercase in responses | Sends uppercase |
| 15 | Thumbnail display | `Image.network` with custom headers | `thumbnail_url` is a complete public CloudFront URL | Plain GET with no headers |
| 16 | Manifest URL | Built on the client as `https://{cloudfront}/{video_s3_key}/manifest.mpd` | `manifest_url` (DASH, `https://<cf>/<uuid>/dash/manifest.mpd`) and `hls_url` (`.../dash/master.m3u8`) come in the response, and are null until COMPLETED | Uses the URL for its platform (D10) and never builds URLs |
| 17 | Renditions and segments | 360p / 720p / 1080p, 6 s segments, 16:9 | 1080p / 720p / 480p bounding boxes, scaled to fit with the source's aspect ratio kept (a portrait source gives 608x1080, 404x720, 270x480); 4 s segments | Takes quality labels and the aspect ratio from the stream |
| 18 | S3 upload body | `file.readAsBytes()` | — | Streams from the file with `Content-Length`, so a 1 GB video isn't held in memory |
| 19 | Base URL | Hard-coded `http://192.168.1.10:8000` | — | `API_BASE_URL` from dart-define |
| 20 | Upload success | Pops back to Home | The new video isn't in the feed until COMPLETED, and then only if PUBLIC | Shows a SnackBar with a "My videos" action |
| 21 | Session check failure | `validateSession` clears the tokens on any non-200 | 503 means Cognito or the database is unavailable | Clears tokens only after a 401 that a refresh can't fix |
| 22 | Refresh | — | Reads only the `refresh_token` cookie, and returns a new refresh token only when rotation is enabled (it isn't today) | Sends the cookie header, and keeps the old refresh token unless a new one arrives |
| 23 | Lost code, forgotten password | — | `POST /auth/resend-otp`, `/auth/forgot-password`, `/auth/reset-password` | Resend button on Confirm Sign Up; Forgot Password and Reset Password screens (§6.8, §6.9) |
| 24 | Error handling | Show the error string | Every error body carries a stable `code` next to `detail` | Branches on `code` (D16, §4.3) |

---

## 4. Backend contract

The base URL comes from `terraform -chdir=backend/terraform output -raw api_url`
and looks like `https://<name>.ecs.<region>.on.aws`. Every request and
response body is JSON.

### 4.1 Endpoints

Auth values: **–** means none; **access** means the Bearer access token;
**refresh** means the refresh cookie.

The errors column lists the `code` values (§4.3) the app branches on. Any
endpoint can also return `validation_error` (400), `too_many_attempts`
(429) on the auth routes, and `database_unavailable` or
`identity_provider_unavailable` (503).

| Method | Path | Auth | Request | 2xx response | Errors the app handles |
|---|---|---|---|---|---|
| POST | `/auth/signup` | – | `{name, email, password}` | 200 `{message}` | `email_exists`, `invalid_password`, `invalid_parameter` (400); `profile_create_failed` (500); `code_delivery_failed` (503) |
| POST | `/auth/verify-otp` | – | `{email, otp}` | 200 `{message}` | `code_mismatch`, `code_expired`, `not_authorized` (already confirmed), `invalid_parameter` (400); `user_not_found` (404) |
| POST | `/auth/resend-otp` | – | `{email}` | 200 `{message}` ("Verification code sent. Check your email.") | `invalid_parameter` (400, e.g. already confirmed); `user_not_found` (404); `code_delivery_failed` (503) |
| POST | `/auth/forgot-password` | – | `{email}` | 200 `{message}`, the same whether or not the account exists | `invalid_parameter` (400, e.g. the email was never verified); `not_authorized` (400); `code_delivery_failed` (503) |
| POST | `/auth/reset-password` | – | `{email, otp, new_password}`; `otp` is 6 digits, `new_password` follows the signup rules | 200 `{message}` ("Password reset. You can log in now.") | `code_mismatch` (also returned for an unknown email), `code_expired`, `invalid_password`, `not_authorized`, `invalid_parameter` (400) |
| POST | `/auth/login` | – | `{email, password}` | 200 `{message}` with two cookies: `access_token` (`Max-Age=3600`, `Path=/`) and `refresh_token` (`Max-Age=432000`, `Path=/auth/refresh`) | `incorrect_credentials`, `user_not_confirmed`, `password_reset_required`, `unsupported_challenge` (400); `user_not_found` (404) |
| POST | `/auth/refresh` | refresh | — | 200 `{message}` with a new `access_token` cookie; also a new `refresh_token` if rotation is enabled | `missing_refresh_token`, `refresh_token_invalid` (401) |
| POST | `/auth/logout` | refresh (optional) | — | 200 `{message}` with cookie-clearing `Set-Cookie` headers | — |
| GET | `/auth/me` | access | — | 200 `UserProfile` | 401 |
| GET | `/upload/video/url` | access | — | 200 `{url, video_id}` | 401; `upload_url_failed` (500) |
| GET | `/upload/video/url/thumbnail` | access | — | 200 `{url, thumbnail_id}` | 401; `upload_url_failed` (500) |
| POST | `/upload/video/save` | access | `{title, description?, visibility, s3_key, thumbnail_s3_key}` | 201 `SaveVideoResponse` | `invalid_s3_key`, `invalid_thumbnail_key` (400); 401; `already_saved` (409) |
| GET | `/video/feed` | – | `?page=1&limit=10` (`limit` 1–50) | 200 `Page<FeedItem>` | — |
| GET | `/video/mine` | access | `?page&limit` | 200 `Page<VideoDetail>` | 401 |
| GET | `/video/{id}` | optional | — | 200 `VideoDetail` | 401; `video_not_found` (404) |
| PATCH | `/video/{id}` | access, owner | `UpdateVideo` (§4.2) | 200 `VideoDetail` | 401; `video_not_found` (404) |
| DELETE | `/video/{id}` | access, owner | — | 204, no body | 401; `video_not_found` (404) |
| GET | `/video/{id}/progress` | optional (owner only for unfinished videos) | — | 200 `Progress` | 401; `video_not_found` (404) |
| POST | `/video/{id}/view` | optional | — | 204, no body | 401; `video_not_found` (404); `video_not_ready` (409) |

A malformed UUID in `{id}` is a `validation_error` (400).

"Optional" auth on the `/video/{id}` read routes works like this:

- Anyone can read a COMPLETED video that is PUBLIC or UNLISTED.
- A PRIVATE or unfinished video is visible only to its owner. Everyone else
  gets 404.
- A token that is present but invalid gets 401 only when ownership decides
  the answer.

PATCH and DELETE need a valid token, and answer 404 to anyone but the owner.
DELETE removes the row at once and the S3 objects shortly after; CloudFront
can keep serving cached segments until their TTL runs out. The app always
attaches the token, so the refresh logic covers every case.

### 4.2 Response shapes

```
UserProfile        { id, name, email, cognito_sub, created_at }
Creator            { id, name }
CreatorDetail      Creator + { created_at }
FeedItem           { id, title, description?, thumbnail_url, manifest_url?, hls_url?,
                     views_count, duration_seconds?, creator: Creator, created_at }
VideoDetail        FeedItem + { creator: CreatorDetail, visibility, status }
Page<T>            { total, page, limit, items: T[] }
SaveVideoResponse  { id, title, status, visibility, created_at }
Progress           { video_id, percent, status }
UpdateVideo        { title?, description?, visibility? }     (request body)
ApiError           { detail: string | ValidationError[], code }
```

- Every `id` is a UUID string, and every timestamp is ISO 8601 with a UTC
  offset.
- `manifest_url` (DASH) and `hls_url` (HLS) are null until the video is
  COMPLETED. `hls_url` also stays null for a video transcoded before the
  pipeline wrote HLS; on iOS such a video can't play (§6.6).
- `duration_seconds` is null if ffprobe couldn't read the duration.
- `views_count` counts `POST /video/{id}/view` calls. `GET /video/{id}` can
  serve a cached copy, so the count it returns can lag by up to an hour
  (§4.5). The feed and My Videos always read the database.
- `creator.id` is the `users.id` UUID, not the Cognito sub.
- `UpdateVideo` changes only the fields present in the body. `title` follows
  the save rules (1–100 characters after trimming); `description` of null or
  `""` clears it; `visibility` is case-insensitive. Sending `title` or
  `visibility` as null is a `validation_error`, so the app omits unchanged
  fields instead of nulling them.

### 4.3 Error bodies

Every error body has a `detail` and a `code`, in one of two shapes:

```json
{"detail": "Incorrect email or password", "code": "incorrect_credentials"}
```

```json
{"detail": [{"type": "value_error", "loc": ["body", "password"],
             "msg": "Value error, password must contain a number", "input": "..."}],
 "code": "validation_error"}
```

The second shape is a validation error. `main.py` remaps FastAPI's 422 to
400.

- **Branch on `code`, never on `detail` (D16).** `code` is a stable
  snake_case contract: the backend adds new codes but never renames or
  reuses one. `detail` is wording for people and can change.
- When `detail` is a string, show it as it is. The backend writes those
  messages for end users.
- When `code` is `validation_error`, `detail` is a list: map `loc.last` to
  the matching form field, and strip the `Value error, ` prefix from `msg`.
- An unknown `code` falls back to showing `detail`, so a new backend code
  never breaks the app.
- The `input` echo can contain the submitted password. That's one more
  reason auth response bodies are never logged (§9).

Codes the app acts on (everything else shows `detail`):

| Code | Status | Where | The app does |
|---|---|---|---|
| `validation_error` | 400 | any form | Field errors under the inputs |
| `email_exists` | 400 | Sign Up | Error under the email field, with a "Sign in instead" link |
| `invalid_password` | 400 | Sign Up, Reset Password | Error under the password field (Cognito's wording) |
| `code_mismatch` | 400 | Confirm, Reset Password | Error under the code field |
| `code_expired` | 400 | Confirm, Reset Password | Error under the code field, and the Resend button is enabled at once |
| `not_authorized` | 400 | Confirm | The account is already confirmed: SnackBar, then Sign In with the email filled in |
| `incorrect_credentials` | 400 | Sign In | Form-level error |
| `user_not_confirmed` | 400 | Sign In | Pushes Confirm Sign Up for the email, and sends a fresh code |
| `password_reset_required` | 400 | Sign In | Pushes Forgot Password with the email filled in |
| `user_not_found` | 404 | Confirm, Sign In, Resend | "No account for this email". Rare, because the pool hides whether an account exists |
| `code_delivery_failed` | 503 | Sign Up, Resend, Forgot Password | "Couldn't send the email, try again" |
| `too_many_attempts` | 429 | auth routes | Form-level error; never retried automatically |
| `missing_access_token`, `token_invalid`, `invalid_token_payload` | 401 | protected routes | One refresh, then a retry (§5.4) |
| `missing_refresh_token`, `refresh_token_invalid` | 401 | `/auth/refresh` | Session ends |
| `already_saved` | 409 | Upload save | Treated as success |
| `video_not_found` | 404 | player, My Videos | "This video isn't available", and the item is dropped from lists |
| `video_not_ready` | 409 | view count | Ignored |
| `identity_provider_unavailable`, `database_unavailable` | 503 | any | Retryable error view; never ends the session |

### 4.4 Auth behaviour the client depends on

- **Every request is checked against Cognito.** The backend validates the
  access token with Cognito `GetUser` on each call, so a token that logout
  revoked fails on the next request.
- **The refresh cookie is scoped to one path.** The backend sets it with
  `Path=/auth/refresh`, so a browser would never send it to
  `/auth/logout`. The app attaches it explicitly to both routes, which means
  logout really does revoke it.
- **No refresh token rotation.** `/auth/refresh` returns only a new access
  token.
- **401 codes**: `missing_access_token`, `token_invalid`, and
  `invalid_token_payload` on protected routes (the interceptor refreshes
  once); `missing_refresh_token` and `refresh_token_invalid` on
  `/auth/refresh` (the session ends).
- **503 is transient.** `identity_provider_unavailable` and
  `database_unavailable` never end the session.
- **429** is `too_many_attempts` ("Too many attempts, try again later").
- **A password reset doesn't sign out other devices.** Refresh tokens issued
  before the reset stay valid until they expire.

### 4.5 Timings and limits

| What | Value | Source |
|---|---|---|
| Access token | 1 h | `ACCESS_COOKIE_MAX_AGE`; Cognito `access_token_validity = 60` minutes |
| Refresh token | 5 days by cookie; Cognito accepts it for 30 | `REFRESH_COOKIE_MAX_AGE`; `IAC/terraform/cognito.tf` |
| Presigned URL | 1 h | `PRESIGNED_URL_TTL_SECONDS` |
| Page size | 1–50, default 10 | `backend/app/routers/video.py` |
| Title | 1–100 characters after trimming | `backend/app/schemas.py` |
| Description | At most 1000 characters; a blank one is stored as null | `backend/app/schemas.py` |
| One S3 PUT | At most 5 GB | S3 limit |
| Completion message redelivery | Every 60 s, 3 receives, then the DLQ | `IAC/terraform/variables.tf` |
| Result for an unsaved upload | Kept 7 days, applied as soon as the save lands | `PARKED_RESULT_TTL` in `backend/app/workers/completion_poller.py` |
| Cached video detail | 1 h. Only `views_count` goes stale, since edits and deletes clear the entry | `VIDEO_META_CACHE_TTL_SECONDS` |
| Verification and reset codes | Cognito's defaults (a confirmation code lasts 24 h, a reset code 1 h) | Cognito |

The transcoder writes progress at 5, 25, 80, 95, and 100 percent. The ffmpeg
stage runs from 25 to 80 without any updates, and it is usually the longest.
A PENDING video reports 0, and the UI shows stage labels, not an ETA.

---

## 5. Architecture

### 5.1 Packages

| Package | Use |
|---|---|
| `flutter_bloc`, `equatable` | Cubits and state equality |
| `dio` | HTTP calls to the API, and the S3 PUTs |
| `flutter_secure_storage` | Tokens |
| `shared_preferences` | The first-run flag and the "has signed in before" flag |
| `image_picker` | Picking the thumbnail and the video |
| `flutter_image_compress` | Re-encoding the thumbnail to JPEG |
| `path_provider` | The application-support directory for upload copies |
| `dotted_border` | The picker boxes |
| `better_player_plus` | DASH and HLS playback |
| `cached_network_image` | Feed thumbnails |
| `intl` | Date and number formatting |
| `wakelock_plus` | Keeping the screen on during an upload |
| Dev: `bloc_test`, `mocktail`, `http_mock_adapter`, `flutter_lints`; `integration_test` (from the SDK) | Tests and lints |

Pin versions when scaffolding (`flutter pub add`), and commit `pubspec.lock`.
Check the Android `minSdk` and the iOS deployment target that each plugin
requires, and set each one to the highest requirement.

### 5.2 Layout

```
frontend/
├── lib/
│   ├── main.dart                      providers, root BlocBuilder, navigator key
│   ├── core/
│   │   ├── config.dart                AppConfig from --dart-define
│   │   ├── api_client.dart            builds the api / bare / s3 Dio instances
│   │   ├── auth_interceptor.dart      Bearer header + single-flight 401 refresh
│   │   ├── cookie_capture.dart        Set-Cookie -> TokenStore
│   │   ├── token_store.dart           flutter_secure_storage wrapper + memory cache
│   │   ├── api_exception.dart         DioException -> ApiException
│   │   ├── validators.dart            mirrors backend/app/schemas.py
│   │   └── format.dart                durations, relative dates
│   ├── models/
│   │   ├── user_profile.dart
│   │   ├── video.dart                 Video, Creator, VideoStatus, VideoVisibility
│   │   ├── page.dart                  Page<T>
│   │   ├── progress.dart
│   │   └── upload_job.dart
│   ├── services/
│   │   ├── auth_service.dart
│   │   ├── video_service.dart
│   │   └── upload_video_service.dart
│   ├── cubits/
│   │   ├── session/                   session_cubit.dart, session_state.dart
│   │   ├── auth/                      auth_cubit.dart, auth_state.dart
│   │   ├── feed/
│   │   ├── my_videos/
│   │   ├── video_detail/
│   │   └── upload_video/
│   ├── pages/
│   │   ├── splash_page.dart
│   │   ├── auth/
│   │   │   ├── sign_up_page.dart
│   │   │   ├── confirm_signup_page.dart
│   │   │   ├── login_page.dart
│   │   │   ├── forgot_password_page.dart
│   │   │   └── reset_password_page.dart
│   │   ├── home_page.dart
│   │   ├── upload_page.dart
│   │   ├── video_player_page.dart
│   │   └── my_videos_page.dart
│   └── widgets/                       video_card, status_chip, dotted_picker, error_view,
│                                      resend_code_button, owner_menu, edit_video_sheet
├── test/                              unit, cubit, widget tests; fixtures/*.json
├── integration_test/
├── env/                               dev.json.example, prod.json.example
├── android/  ios/
├── analysis_options.yaml
├── pubspec.yaml
└── README.md
```

Page file paths follow the spec's summary matrix. The spec names the home
page file both `homepage.dart` and `home_page.dart`; this plan uses
`home_page.dart`.

### 5.3 Configuration

```dart
class AppConfig {
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL');
  static const maxUploadBytes =
      int.fromEnvironment('MAX_UPLOAD_BYTES', defaultValue: 2147483648); // 2 GiB
  static const httpLogs = bool.fromEnvironment('HTTP_LOGS');
}
```

Run with `flutter run --dart-define-from-file=env/dev.json`. `main()` fails
fast if `API_BASE_URL` is empty.

The env files hold no secrets because the app has none: the Cognito client
secret never leaves the backend. The real `env/*.json` files are still
gitignored, so they don't churn between developers.

### 5.4 Networking

The app uses three `Dio` instances:

| Instance | Base URL | Interceptors | Used for |
|---|---|---|---|
| `api` | `API_BASE_URL` | `CookieCapture`, `AuthInterceptor`, and in debug a `LogInterceptor` with headers and bodies off | Every API call |
| `bare` | `API_BASE_URL` | `CookieCapture` | `/auth/refresh`, `/auth/logout`, and the retry after a refresh |
| `s3` | none | none | Presigned PUTs |

`s3` must never carry an `Authorization` header, for two reasons. S3 rejects
a request that has both a presigned signature and an `Authorization` header
("Only one auth mechanism allowed"). And the token must not leave the API's
origin.

Timeouts:

- `api` and `bare`: `connectTimeout` 10 s, `receiveTimeout` 30 s.
- `s3`: `connectTimeout` 15 s, no send timeout, `receiveTimeout` 60 s.

**Cookie capture** runs on every `api` and `bare` response:

```dart
final _cookie = RegExp(r'^(access_token|refresh_token)=("?)([^";]*)\2');
final _maxAge = RegExp(r';\s*max-age=(-?\d+)', caseSensitive: false);

class CookieCapture extends Interceptor {
  CookieCapture(this._tokens);
  final TokenStore _tokens;

  @override
  Future<void> onResponse(Response response, ResponseInterceptorHandler handler) async {
    for (final raw in response.headers['set-cookie'] ?? const <String>[]) {
      final match = _cookie.firstMatch(raw);
      if (match == null) continue;
      final value = match.group(3)!;
      final maxAge = int.tryParse(_maxAge.firstMatch(raw)?.group(1) ?? '');
      if (value.isEmpty || (maxAge != null && maxAge <= 0)) {
        await _tokens.delete(match.group(1)!);   // logout clears with ="" and Max-Age=0
      } else {
        await _tokens.save(match.group(1)!, value, maxAgeSeconds: maxAge);
      }
    }
    handler.next(response);
  }
}
```

**Refresh.** `AuthInterceptor` is a `QueuedInterceptor`:

- It adds the Bearer header to each request.
- When several requests get 401 at once, dio queues their error handlers.
  The first one refreshes, and the rest see that the stored token has changed
  and just retry.
- Retries go through `bare`, not `api`. Otherwise a retry that fails again
  would wait behind the handler that is waiting for it, and deadlock.

This is a sketch; check it against the pinned dio version.

```dart
class AuthInterceptor extends QueuedInterceptor {
  AuthInterceptor(this._tokens, this._bare, this._onSessionExpired);

  final TokenStore _tokens;
  final Dio _bare;
  final void Function() _onSessionExpired;

  static const _skip = {
    '/auth/signup', '/auth/verify-otp', '/auth/resend-otp', '/auth/forgot-password',
    '/auth/reset-password', '/auth/login', '/auth/refresh', '/auth/logout',
  };

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    final token = await _tokens.accessToken();
    if (token != null) options.headers['Authorization'] = 'Bearer $token';
    handler.next(options);
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final request = err.requestOptions;
    if (err.response?.statusCode != 401 ||
        _skip.contains(request.path) ||
        request.extra['retried'] == true) {
      return handler.next(err);
    }

    final current = await _tokens.accessToken();
    final alreadyRefreshed =
        current != null && request.headers['Authorization'] != 'Bearer $current';
    if (!alreadyRefreshed && !await _refresh()) {
      await _tokens.clear();
      _onSessionExpired();
      return handler.next(err);
    }

    request
      ..headers['Authorization'] = 'Bearer ${await _tokens.accessToken()}'
      ..extra['retried'] = true;
    try {
      handler.resolve(await _bare.fetch(request));
    } on DioException catch (e) {
      handler.next(e);
    }
  }

  Future<bool> _refresh() async {
    final refresh = await _tokens.refreshToken();
    if (refresh == null) return false;
    try {
      await _bare.post('/auth/refresh',
          options: Options(headers: {'Cookie': 'refresh_token=$refresh'}));
      return true;                               // CookieCapture stored the new access token
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) return false;
      rethrow;                                   // network / 5xx: keep the session, surface the error
    }
  }
}
```

A network error or 5xx during refresh surfaces to the caller as a normal
error, and the session is kept. Only a 401 from `/auth/refresh` ends the
session.

### 5.5 Token storage and session lifecycle

`TokenStore` wraps `flutter_secure_storage`. It holds four keys:
`access_token`, `access_expires_at`, `refresh_token`, and
`refresh_expires_at`. Each expiry is computed from the cookie's `Max-Age`
when the token is saved.

- `refreshToken()` returns null once the refresh token has expired. The
  session then ends without a network call (D8).
- `accessToken()` returns whatever is stored, and the server's 401 drives
  the refresh. That keeps the logic in one place.
- Values are cached in memory after the first read, because secure-storage
  reads are slow on some Android devices.
- **First-run wipe.** iOS Keychain items survive an app uninstall, but
  `shared_preferences` does not. On startup, if the `installed` flag is
  missing, the app clears the `TokenStore` and then sets the flag. A
  reinstalled app therefore starts signed out.

Session lifecycle (`SessionCubit`):

```
restore():  no refresh token (or expired)       -> Unauthenticated
            GET /auth/me OK (after any refresh) -> Authenticated(user)
            401 that refresh can't fix          -> Unauthenticated (tokens cleared)
            network error / 503                 -> Unavailable (tokens kept, Retry)
signedIn(user)                                  -> Authenticated(user)
expired()   (from AuthInterceptor)              -> Unauthenticated + "Session expired" message
logout():   POST /auth/logout (bare, Cookie: refresh_token=...), ignore its result,
            clear TokenStore                    -> Unauthenticated
```

### 5.6 State management

Each cubit's states are sealed classes extending `Equatable`.

| Cubit | Scope | States | Methods |
|---|---|---|---|
| `SessionCubit` | App root | `SessionUnknown`, `SessionAuthenticated(user)`, `SessionUnauthenticated(message?)`, `SessionUnavailable(message)` | `restore`, `signedIn`, `expired`, `logout` |
| `AuthCubit` | Created per auth page by its `route()` | `AuthInitial`, `AuthLoading`, `AuthSignUpSuccess(email)`, `AuthConfirmSignUpSuccess(email)`, `AuthNeedsVerification(email)`, `AuthNeedsPasswordReset(email)`, `AuthCodeSent`, `AuthResetCodeSent(email)`, `AuthPasswordResetSuccess(email)`, `AuthLoginSuccess(user)`, `AuthError(message, code, fieldErrors)` | `signUpUser`, `confirmSignUpUser`, `resendCode`, `forgotPassword`, `resetPassword`, `loginUser` |
| `FeedCubit` | Home page | `FeedState{items, page, total, status, error}`, where `status` is `initial`, `loading`, `loadingMore`, `refreshing`, `success`, or `failure` | `load`, `loadMore`, `refresh`, `remove(id)` |
| `MyVideosCubit` | My Videos page | Like `FeedState`, plus `progress: Map<id, Progress>` | `load`, `loadMore`, `refresh`, `update(id, changes)`, `delete(id)`, and a polling timer (§6.7) |
| `VideoDetailCubit` | Player page | `loading`, `ready(video)`, `processing(video, progress)`, `failed(video)`, `notFound`, `deleted`, `error` | `load(id)`, polling while processing, `recordView()`, `update(changes)`, `delete()` |
| `UploadVideoCubit` | Upload page | `UploadVideoInitial`, `UploadVideoInProgress(stage, sentBytes, totalBytes)`, `UploadVideoSuccess(saved)`, `UploadVideoError(message, stage)` | `uploadVideo`, `cancel`, `retry` |

`AuthCubit` keeps the spec's state names and adds the resend and reset
states. On a successful login it calls `SessionCubit.signedIn(user)`, and
that call is what switches the root. Because `AuthCubit` is created per
page, a lingering `AuthError` on one screen never shows up on another.

Edits and deletes change lists on other pages. The player page returns
`VideoChange.updated(video)` or `VideoChange.deleted(id)` when it pops, and
My Videos applies it; Home calls `FeedCubit.remove(id)` on a delete, or on
an edit that made the video non-PUBLIC. Nothing else is cached across pages,
so a pull-to-refresh fixes anything this misses.

### 5.7 Navigation

The root switches on `SessionCubit`:

```dart
BlocConsumer<SessionCubit, SessionState>(
  listenWhen: (prev, next) => prev.runtimeType != next.runtimeType,
  // Pages pushed on top of the old root (the auth stack, or Upload when a
  // session expires) would otherwise stay visible over the new root.
  listener: (context, state) => navigatorKey.currentState?.popUntil((r) => r.isFirst),
  builder: (context, state) => switch (state) {
    SessionUnknown() || SessionUnavailable() => const SplashPage(),
    SessionAuthenticated() => const HomePage(),
    SessionUnauthenticated() => hasSignedInBefore ? const LoginPage() : const SignUpPage(),
  },
)
```

The spec makes Sign Up the entry screen for new users. After a logout or an
expired session, the root shows Sign In instead, based on a
`has_signed_in_before` flag in `shared_preferences`.

The routes are `SignUpPage.route()`, `ConfirmSignUpPage.route(email)`,
`LoginPage.route({email})`, `ForgotPasswordPage.route({email})`,
`ResetPasswordPage.route(email)`, `UploadPage.route()`,
`VideoPlayerPage.route(video)`, and `MyVideosPage.route()`.

### 5.8 Models

```dart
enum VideoStatus { pending, processing, completed, failed, unknown }
enum VideoVisibility { public, private, unlisted, unknown }   // not "Visibility": clashes with the Flutter widget
```

- Enums are parsed from the uppercase wire value. An unrecognised value maps
  to `unknown`, so a new backend value doesn't crash the app.
- A single `Video` class covers both `FeedItem` and `VideoDetail`. It has
  `id`, `title`, `description?`, `thumbnailUrl`, `manifestUrl?`, `hlsUrl?`,
  `viewsCount`, `durationSeconds?`, `creator` (`id`, `name`,
  `createdAt?`), `createdAt`, `visibility?`, and `status?`.
- Feed items leave `visibility` and `status` null, meaning PUBLIC and
  COMPLETED.
- `playbackUrl` picks the URL for the platform: `hlsUrl` on iOS,
  `manifestUrl` on Android. `isPlayable` is `playbackUrl != null`.
- `copyWith` exists so an edit or a view can update a `Video` in place.
- `VideoUpdate` is the PATCH body. It serialises only the fields that
  changed (§4.2), and `description: ''` clears the description.
- `Page<T>` has `total`, `page`, `limit`, and `items`. `hasMore` is
  `page * limit < total`.

### 5.9 Error handling

`ApiException` carries `statusCode?`, `code?`, `message`, `fieldErrors` (a
`Map<String, String>`), and `kind`. `code` is the body's `code` (§4.3), and
is null for network errors and for bodies that aren't JSON (an ALB 502, for
example). `kind` is one of `network`, `timeout`, `badRequest`,
`unauthorized`, `notFound`, `conflict`, `throttled`, `server`, or
`unavailable`, derived from the status. Services throw only `ApiException`.

Cubits and pages branch on `code` first, using the table in §4.3. The
`kind` rows below are the fallback for codes the app doesn't know.

| Condition | UX |
|---|---|
| No connection or a timeout | Inline error with a Retry button. Forms keep their input |
| `validation_error` | The messages appear under the matching fields |
| Other 400 | A red SnackBar showing `detail` |
| 401 on a protected call | The interceptor refreshes. If that fails, the root returns to Sign In with "Session expired, sign in again" |
| 404 on a video | A "This video isn't available" view |
| `already_saved` | Treated as already saved |
| 429 | A SnackBar showing `detail` |
| 500 | "Something went wrong", plus `detail` |
| 503 | "Service temporarily unavailable" with Retry. Never ends the session |

---

## 6. Screens

### 6.0 Splash (launch gate) — new

- Runs `SessionCubit.restore()` (§5.5), including the first-run wipe.
- In the `SessionUnavailable` state it shows "Can't reach the server" with a
  Retry button, and keeps the stored tokens.
- **Acceptance:**
  - A cold start with a valid session lands on Home without showing Sign In
    first.
  - Launching in airplane mode with a saved session shows Retry, not Sign In.

### 6.1 Sign Up (`lib/pages/auth/sign_up_page.dart`)

**Layout** as in the spec: a "Sign Up" title, then the Name, Email, and
Password fields, a Sign Up button, and an "Already have an account? Sign In"
link.

**Controllers:** `_formKey`, `nameController`, `emailController`,
`passwordController`.

**Validation** (`core/validators.dart`, mirroring `schemas.py`):

| Field | Rules | Input settings |
|---|---|---|
| Name | Trimmed; 2–50 characters | `autofillHints: [AutofillHints.name]` |
| Email | Trimmed; a basic format check; at most 255 characters; lowercased before sending | `TextInputType.emailAddress`, `autofillHints: [AutofillHints.email]` |
| Password | 8–256 characters, with an uppercase letter, a lowercase letter, a digit, and a special character. The first rule that fails is shown | Obscured with a show/hide toggle; `autofillHints: [AutofillHints.newPassword]` |

**Flow:**

1. The user taps Sign Up and the form validates.
2. `signUpUser` calls `POST /auth/signup`.
3. On `AuthSignUpSuccess(email)`, a SnackBar says "Check your email for the
   verification code", and `ConfirmSignUpPage.route(email)` is pushed.

The button shows a spinner and is disabled while the state is `AuthLoading`.

**Errors:**

- `validation_error` is shown under the matching fields.
- `invalid_password` is shown under the password field. The client rules
  should catch it first; the server message is Cognito's wording.
- `email_exists` appears under the email field with two actions: "Sign in",
  and "Verify this email", which pushes Confirm Sign Up and calls
  `resendCode`. A user who signed up but lost the code gets out this way.
- `code_delivery_failed` means the account was created but the email didn't
  go out. The app still pushes Confirm Sign Up, where Resend is enabled at
  once.

**Acceptance:**

- A weak password is rejected on the client.
- A server-side validation error appears under the matching field.
- A successful signup lands on Confirm Sign Up with the email pre-filled.

### 6.2 Confirm Sign Up (`lib/pages/auth/confirm_signup_page.dart`)

**Layout** as in the spec: a title, an Email field (pre-filled and editable,
so a user arriving from Sign In can fix a typo), an OTP field, a Confirm
button, and a "Back to sign in" link. Added: a "Resend code" text button
under the OTP field.

**OTP field:** exactly 6 digits, `TextInputType.number`, `maxLength: 6`,
`FilteringTextInputFormatter.digitsOnly`, and
`autofillHints: [AutofillHints.oneTimeCode]`.

- **Deviation:** the spec obscures this field. The plan leaves it visible,
  because obscuring a code the user is copying from an email causes typos.
  Changing it back is a single flag.

**Flow:**

1. `confirmSignUpUser` calls `POST /auth/verify-otp` with `{email, otp}`.
2. On `AuthConfirmSignUpSuccess`, a SnackBar says "User confirmed
   successfully", and `pushReplacement(LoginPage.route(email: email))` runs.

**Resend** (`widgets/resend_code_button.dart`, shared with Reset Password):

- `resendCode` calls `POST /auth/resend-otp` with the email field's value.
- On `AuthCodeSent`, a SnackBar shows the server's message, and the button
  becomes "Resend in 60 s", counting down. The cooldown is the app's own; it
  keeps users from hitting Cognito's rate limit.
- The cooldown starts when the page opens straight after a signup, because a
  code has just been sent. It doesn't start when the page opens from Sign In
  (`user_not_confirmed`), since the code sent at signup may have expired.

**Errors:**

- `code_mismatch` and `code_expired` appear under the OTP field. On
  `code_expired` the cooldown is cleared, so Resend works at once.
- `not_authorized` means the account is already confirmed. A SnackBar says
  "This account is already verified", and Sign In replaces the page with the
  email filled in.
- A Resend for a confirmed account returns `invalid_parameter` ("User is
  already confirmed."). That code covers other bad input too, so the app
  shows `detail` and leaves the "Back to sign in" link to cover it.
- `user_not_found` shows "No account for this email" under the email field.
- `code_delivery_failed` and `too_many_attempts` appear in a SnackBar.

**Acceptance:**

- A wrong code shows an error under the field; the right one lands on Sign
  In with the email filled in.
- Resend delivers a new code, and the button stays disabled for 60 s.
- An already-verified account is sent to Sign In, not left on an error.

### 6.3 Sign In (`lib/pages/auth/login_page.dart`)

**Layout** as in the spec: a title, Email and Password fields
(`AutofillHints.password`), a Sign In button, and a "Don't have an account?
Sign Up" link. Added: a "Forgot password?" link under the password field,
which pushes `ForgotPasswordPage.route(email: <email field>)`.

**Flow:**

1. `loginUser` calls `POST /auth/login`.
2. `CookieCapture` stores both tokens. No page or service parses cookies
   itself.
3. `GET /auth/me` loads the profile.
4. `SessionCubit.signedIn(user)` switches the root to Home, and the root
   listener pops the auth pages.

If the login succeeds but no token was captured, the app reports "Sign-in
failed". That would mean something between the app and the API stripped the
`Set-Cookie` headers.

**Errors:**

| Code | What happens |
|---|---|
| `incorrect_credentials` | "Incorrect email or password" as a form-level error. The password field is cleared |
| `user_not_confirmed` | `AuthNeedsVerification(email)`, which pushes Confirm Sign Up and calls `resendCode` so a fresh code is on its way |
| `password_reset_required` | `AuthNeedsPasswordReset(email)`, which pushes Forgot Password with the email filled in |
| `user_not_found` | "No account for this email", with a "Sign up" action |
| `unsupported_challenge` | "This account needs a sign-in step the app doesn't support" (MFA is off in the pool, so this shouldn't happen) |
| `too_many_attempts` | Shown in a SnackBar |

**Acceptance:**

- After a successful sign-in, killing the app and relaunching it lands on
  Home.
- An unconfirmed account is taken to Confirm Sign Up, and a new code
  arrives.
- "Forgot password?" opens Forgot Password with the typed email carried
  over.

### 6.4 Home Feed (`lib/pages/home_page.dart`)

**App bar:**

- The title "Video Stream".
- A `+` button that pushes `UploadPage.route()`.
- A profile menu with "My videos" and "Log out". The user's name comes from
  the session.

**Body:**

- A `RefreshIndicator` around a `ListView.builder`, backed by `FeedCubit`
  with `limit=10`.
- `loadMore` fires when the list is within 3 items of its end. A footer shows
  a spinner while loading, and nothing once `hasMore` is false.
- Items are de-duplicated by `id`. Offset pagination shifts when new videos
  complete, so the same video can arrive on two pages.

**Video card:**

- A 16:9 `CachedNetworkImage` of `thumbnail_url` with a placeholder and an
  error icon.
- A duration badge in the corner (`m:ss` or `h:mm:ss`), hidden when the
  duration is null.
- The title in bold, at most 2 lines.
- `creator.name · 1.2K views · 3 days ago` below it. The count uses
  `NumberFormat.compact()`.
- No status chip, because feed items are always COMPLETED.

**Interactions:** tapping a card pushes `VideoPlayerPage.route(video)`.

**Empty and error states:** an empty feed shows "No videos yet" with an
Upload button. A failed load shows `ErrorView` with Retry.

**Acceptance:**

- With 25 public videos, the feed loads 3 pages, stops at `total`, and shows
  no duplicates.
- Pull-to-refresh reloads from page 1.

### 6.5 Upload Video (`lib/pages/upload_page.dart`)

**Layout** as in the spec:

- A thumbnail picker: `DottedBorder` (height 150, dash pattern `[10, 4]`)
  showing `Icons.folder_open` and "Select the thumbnail for your video".
  After a pick it shows `Image.file` with `BoxFit.cover`.
- A video picker: `Icons.video_file_outlined` and "Select your video file".
  After a pick it shows the file name and size.
- A Title field, and a Description field (`maxLines: null`, with a
  1000-character counter).
- A visibility dropdown (Public, Private, Unlisted), defaulting to Private
  as in the spec.
- The Upload button.

**Pickers and checks:**

- Images are picked with `ImagePicker().pickImage(source: gallery)`, and
  videos with `pickVideo(source: gallery)`.
- The video must be `.mp4`, `.mov`, or `.m4v`, larger than 0 bytes, and no
  larger than `MAX_UPLOAD_BYTES`. MP4 and MOV share an ffmpeg demuxer, and
  ffmpeg reads the container from the content, so a MOV uploaded under the
  `.mp4` key transcodes.
- The thumbnail is re-encoded to JPEG with `flutter_image_compress`
  (`CompressFormat.jpeg`, quality 85, at least 1280 px wide).

**Validation:**

- A thumbnail and a video are both required. The backend requires
  `thumbnail_s3_key`.
- The title must be 1–100 characters after trimming.
- The description can be at most 1000 characters.

**Progress:**

- Instead of the spec's spinner, a stage label ("Uploading thumbnail",
  "Uploading video", "Saving") sits above a `LinearProgressIndicator`.
- During the video PUT the bar is determinate, showing MB sent of the total.
- A Cancel button stops the transfer (dio `CancelToken`).
- While an upload runs, `PopScope` asks "Cancel upload?" before leaving, and
  `wakelock_plus` keeps the screen on.
- A note reads "Keep the app open until the upload finishes" (§7.6).

**Success:** a green SnackBar says "Video uploaded. Processing has started."
with a "My videos" action, and the page pops back to Home.

**Error:** a SnackBar shows the message. Retry keeps the form, and resumes
from the stage that failed (§7.3).

**Acceptance:**

- A 200 MB video uploads with visible progress.
- The video appears in My Videos as PENDING or PROCESSING within seconds of
  the upload finishing.
- Cancelling mid-transfer leaves no saved row.

### 6.6 Video Player (`lib/pages/video_player_page.dart`)

**Input:** the page receives a `Video` from the feed or from My Videos. It
renders that video's title and description straight away, then calls
`VideoDetailCubit.load(id)` to fetch the full detail (`GET /video/{id}`).

**States:**

- **ready:** a `BetterPlayer` at the top, playing `video.playbackUrl`, the
  URL for the current platform (§8.1). On iOS a COMPLETED video with a null
  `hls_url` (transcoded before HLS existed) shows "This video can't play on
  iPhone yet" instead of a player.
- **processing:** shown for the owner's unfinished video. The player area
  shows the status and progress. The cubit polls
  `GET /video/{id}/progress` every 5 s. When the status reaches COMPLETED,
  it fetches the detail again and starts the player.
- **failed:** "Processing failed", with the owner menu's Delete as the way
  out.
- **notFound:** "This video isn't available".
- **deleted:** the page pops at once (see Owner actions).

**Player size (D17):**

- The box starts at 16:9, the right shape for a landscape video and a
  reasonable placeholder for the rest.
- When the player reports it is initialised, the page reads the video's
  aspect ratio and resizes the box to it. A portrait video becomes 9:16.
- The box is capped at 60% of the screen height, with `BoxFit.contain`
  inside it, so a portrait video leaves the details panel visible and is
  pillarboxed rather than cropped.
- Fullscreen uses the video's own aspect ratio and orientation, so a
  portrait video stays upright in fullscreen.

**View count (D18):**

- The first time playback starts on this page, the cubit calls
  `POST /video/{id}/view` once, fire-and-forget. Replays, seeks, and
  fullscreen toggles on the same page don't count again.
- The count on screen goes up by one straight away. Errors are ignored:
  `video_not_ready` can't happen for a playing video, and a lost view isn't
  worth a retry.

**Controls:**

- Play/pause, a seek bar, and fullscreen.
- A quality menu, whose tracks come from the manifest: Auto, 1080p, 720p,
  and 480p.
- A speed menu with 0.5×, 1.0×, 1.5×, and 2.0×, if the package lets you
  restrict the list. Otherwise the package's default list is fine.

**Details panel:**

- The title in bold.
- `1,234 views · 3 days ago`.
- An expandable description.
- The creator's name and "Joined <Month YYYY>" (from `creator.created_at`).
- A visibility chip, shown only when the viewer owns the video.

**Owner actions:** when `video.creator.id == session.user.id`, the app bar
has a `⋮` menu (`widgets/owner_menu.dart`) with Edit and Delete. The same
menu is on My Videos cards.

- **Edit** opens `widgets/edit_video_sheet.dart`, a bottom sheet with Title,
  Description, and Visibility, filled in from the video.
  - Validation is the upload form's (§6.5).
  - Save stays disabled until something changes, and the request carries
    only the changed fields (`VideoUpdate`, §5.8). Clearing the description
    sends `""`.
  - A 200 returns the new `VideoDetail`, which replaces the video on the
    page. The page pops with `VideoChange.updated(video)` (§5.6).
  - `validation_error` appears under the fields. `video_not_found` means the
    video was deleted elsewhere: the sheet closes and the page shows
    notFound.
- **Delete** asks "Delete this video? This can't be undone."
  - On confirm the player is paused, then `DELETE /video/{id}` is sent.
  - 204, or a `video_not_found` (already gone), pops the page with
    `VideoChange.deleted(id)` and a SnackBar "Video deleted".
  - Delete works in any status, including PENDING, PROCESSING, and FAILED.

**Lifecycle:** `dispose()` calls `_betterPlayerController.dispose()`.

**Acceptance:**

- On Android, a feed video plays with DASH and switches quality from the
  menu. On iOS, the same video plays with HLS.
- A portrait video plays upright in a portrait box, inline and in
  fullscreen.
- Playing a video once raises its count by one, even after a replay; opening
  the page again and playing counts again.
- Fullscreen and rotation work.
- Leaving the page stops the audio.
- An owner opening their processing video sees the player start by itself
  when processing finishes.
- An owner can edit the title and visibility and sees the change without a
  reload; a video made PRIVATE disappears from Home on return.
- An owner can delete a video, and it is gone from My Videos and Home on
  return. A non-owner sees no menu.

### 6.7 My Videos (`lib/pages/my_videos_page.dart`) — new

**Entry points:** the Home profile menu, and the upload SnackBar.

**List:**

- `GET /video/mine`, paginated, with pull-to-refresh.
- Each card shows a status chip (Pending, Processing, Ready, Failed), a
  visibility chip, the date, and, for Ready videos, the view count.
- PENDING and PROCESSING cards also show a progress bar.
- Each card has the owner menu (Edit, Delete) from §6.6. `update` and
  `delete` on `MyVideosCubit` change the item in place or drop it, and
  `total` goes down by one on a delete.

**Polling:**

- `MyVideosCubit` runs a 5 s timer while the page is visible and at least
  one loaded item is PENDING or PROCESSING.
- Each tick calls `/progress` for at most 10 of those items.
- When an item turns COMPLETED or FAILED, the cubit fetches `/video/{id}`
  again to pick up `manifest_url`, `hls_url`, and `duration_seconds`.
- A `video_not_found` from either call drops the item, because the video was
  deleted on another device.
- The timer pauses when the app goes to the background (`AppLifecycleListener`)
  and stops when the cubit closes.

**Labels:**

- PENDING at 0% shows "Waiting to process".
- A video still PENDING 15 minutes after `created_at` shows "Taking longer
  than usual". A late save no longer causes this (the backend applies the
  parked result, §7.4), so it now points to a stuck pipeline: a full ingest
  queue or a transcoder that failed to start.

**Tapping a card:**

| Status | Action |
|---|---|
| COMPLETED | Opens the player |
| PENDING or PROCESSING | Opens the player in processing mode |
| FAILED | Explains that processing failed and offers Delete. There is no retry: the user uploads again |

**Acceptance:**

- With the screen open after an upload, the video moves from Pending to
  Processing (with a percentage) to Ready without a manual refresh.
- Editing or deleting from a card updates the list without a reload.
- A FAILED video can be deleted.

### 6.8 Forgot Password (`lib/pages/auth/forgot_password_page.dart`) — new

**Entry points:** "Forgot password?" on Sign In, and a
`password_reset_required` answer to a login.

**Layout:** a "Reset your password" title, a line saying "We'll email you a
code", an Email field (filled in from the route argument), a Send code
button, and a "Back to sign in" link.

**Flow:**

1. `forgotPassword` calls `POST /auth/forgot-password` with `{email}`.
2. The answer is the same whether or not an account exists, so the app never
   says whether one does.
3. On `AuthResetCodeSent(email)`, `pushReplacement(ResetPasswordPage.route(email))`
   runs, with a SnackBar showing the server's message.

**Errors:**

- `invalid_parameter` usually means the account's email was never verified,
  so Cognito can't send a reset code to it. The app shows `detail` and a
  "Verify email" action, which pushes Confirm Sign Up and calls
  `resendCode`.
- `code_delivery_failed`, `not_authorized`, and `too_many_attempts` appear
  in a SnackBar.

**Acceptance:** an existing and a made-up email both land on Reset Password
with the same message.

### 6.9 Reset Password (`lib/pages/auth/reset_password_page.dart`) — new

**Layout:** a title, the email as read-only text with a "Change" link (back
to Forgot Password), an OTP field (the same settings as §6.2), a New
password field (the signup rules, `AutofillHints.newPassword`, show/hide
toggle), a Reset password button, and the Resend button from §6.2.

**Flow:**

1. `resetPassword` calls `POST /auth/reset-password` with
   `{email, otp, new_password}`.
2. On `AuthPasswordResetSuccess(email)`, a SnackBar says "Password reset. You
   can log in now." and `pushAndRemoveUntil` leaves Sign In on the stack with
   the email filled in.
3. Resend here calls `POST /auth/forgot-password` again, not
   `/auth/resend-otp`, which only sends signup codes. The 60 s cooldown
   starts when the page opens, because a code was just sent.

**Errors:**

- `code_mismatch` appears under the OTP field. The backend also returns it
  for an email with no account, so the message stays "Invalid code".
- `code_expired` appears under the OTP field and clears the Resend cooldown.
- `invalid_password` and `validation_error` appear under the fields.
- `not_authorized`, `invalid_parameter`, and `too_many_attempts` appear in a
  SnackBar.

A reset doesn't sign out the user's other devices (§4.4).

**Acceptance:**

- The right code and a valid password land on Sign In, and the new password
  works.
- A weak password is rejected on the client; a wrong code shows under the
  field.

---

## 7. Upload pipeline

### 7.1 Sequence

```
UploadVideoCubit                         API                                  S3
 |-- validate; copy both files to <app support>/uploads/<localId>/
 |-- GET /upload/video/url/thumbnail ---> {url, thumbnail_id}
 |-- PUT thumbnail (image/jpeg) ------------------------------------------> thumbnails bucket
 |-- GET /upload/video/url -------------> {url, video_id}
 |-- PUT video (video/mp4, streamed) -------------------------------------> raw bucket
 |                                                                            (starts the transcode)
 |-- POST /upload/video/save {title, description, visibility,
 |        s3_key: video_id, thumbnail_s3_key: thumbnail_id} --> 201 {id, status: PENDING, ...}
 |-- delete the local copies
```

Two small changes to the spec's order:

- Each presigned URL is fetched just before its PUT, so its one-hour
  lifetime starts as late as possible.
- The thumbnail goes first. It's small, and if it fails nothing has started
  in the pipeline.

The files are copied into application support instead of the spec's
Documents directory. On iOS, Documents can be shown in the Files app, and
these copies are temporary.

### 7.2 PUT requirements

- **Exact Content-Type.** It must be `video/mp4` or `image/jpeg`, exactly.
  The content type is part of the presigned signature, so any other value
  fails with `403 SignatureDoesNotMatch`.
- **Only Content-Type and Content-Length.** Don't send `x-amz-acl` or
  `Authorization`.
- **Stream the file** with an explicit `Content-Length`. S3 doesn't accept
  chunked uploads on a presigned PUT.
- **Use the URL exactly as returned.** Rebuilding it from parts re-encodes
  the query string and breaks the signature.
- **Success is 200.**

```dart
Future<void> put(String url, File file, String contentType,
    {ProgressCallback? onProgress, CancelToken? cancel}) async {
  await _s3.put<void>(
    url,
    data: file.openRead(),
    options: Options(headers: {
      Headers.contentTypeHeader: contentType,
      Headers.contentLengthHeader: await file.length(),
    }),
    onSendProgress: onProgress,
    cancelToken: cancel,
  );
}
```

### 7.3 Failures and retry

| Failed stage | What a retry does |
|---|---|
| Thumbnail URL or thumbnail PUT | Starts again from the thumbnail URL |
| Video URL | Fetches the URL again |
| Video PUT (network error or 5xx) | Reuses the same URL while it is less than 55 minutes old; otherwise fetches a new one, which means a new key. A PUT replaces the whole object, so a partial attempt leaves nothing behind. It retries 3 times automatically with backoff, then offers a manual Retry |
| Video PUT returns 403 | Fetches a new URL (the old one expired or its signature didn't match) and retries once |
| Save (network error, 5xx, or 503) | Retries only the save and never re-uploads. `already_saved` (409) means the save already went through: treat it as success, and My Videos will show the video |
| Save returns 400 | A client bug (`invalid_s3_key`, `invalid_thumbnail_key`, or `validation_error`). Show the error and keep the job so it can be inspected |
| 401 at any stage | The interceptor refreshes the token. If the session has ended, the job is kept (M4), the user signs in again, and the upload resumes |

### 7.4 The save window

The transcode starts when the video PUT finishes, before the app calls save,
so the pipeline can finish a video that has no `videos` row yet. In the
normal flow that can't happen: the save lands within a second of the PUT,
and a transcode first waits for the Lambda batch window, then a Fargate task
start, then ffmpeg.

It can happen if the app is killed between the PUT's 200 response and the
save's 201. The backend covers that case (B5):

- The poller parks a `completed` or `failed` result that has no row in its
  `transcode_results` table, instead of retrying it into the DLQ.
- When the save creates the row, the poller applies the parked result on
  its next loop, within seconds. The video goes straight from PENDING to
  COMPLETED (or FAILED), and My Videos shows that on its next poll.
- A parked result is kept for 7 days. A save later than that leaves the row
  PENDING for good.

The M4 rule stays as a nicety, and to stay inside those 7 days: on each
authenticated launch, a job whose video was uploaded but not yet saved is
saved at once, before anything else.

### 7.5 Resumable jobs (M4)

An `UploadJob` is stored as JSON in `<app support>/uploads/<localId>/job.json`
and rewritten after every stage.

It holds:

- `localId`, `title`, `description`, `visibility`
- `videoPath`, `thumbnailPath`
- `thumbnailKey`, `thumbnailUploaded`
- `videoKey`, `videoUrl`, `videoUrlIssuedAt`, `videoUploaded`
- `savedVideoId`

On each authenticated launch:

1. Jobs with `videoUploaded && savedVideoId == null` are saved immediately
   (§7.4).
2. Any other unfinished job shows an "Unfinished upload" banner on Home with
   Resume and Discard.
3. After a successful save, the job and its files are deleted.

### 7.6 Background uploads

v1 uploads only in the foreground. iOS suspends a backgrounded app within
seconds, which breaks a large PUT in flight. The app keeps the screen on
during an upload and asks the user to keep it open.

For a later milestone, evaluate `background_downloader`. It uses the
platform's background transfer services, but first confirm it can send a raw
binary PUT with a fixed Content-Type.

---

## 8. Playback

### 8.1 Platform matrix

| Platform | DASH (`manifest_url`) | HLS (`hls_url`) |
|---|---|---|
| Android | Yes, through ExoPlayer | Yes |
| iOS | No. AVPlayer has no DASH support | Yes |
| Web (deferred) | Needs a JavaScript player (dash.js or Shaka) | Plays natively in Safari; other browsers need hls.js |

The app plays `manifest_url` on Android and `hls_url` on iOS
(`Video.playbackUrl`, §5.8). Android stays on DASH because S1 tests it and
ExoPlayer's DASH track selection drives the quality menu. On iOS a video
with a null `hls_url` shows "This video can't play on iPhone yet" instead of
a player that fails (§6.6). Only videos transcoded before HLS output existed
are like that; re-uploading one fixes it.

### 8.2 Player setup (sketch; check the names against the pinned package)

```dart
_controller = BetterPlayerController(
  const BetterPlayerConfiguration(
    aspectRatio: 16 / 9,                         // placeholder until the video reports its own
    fit: BoxFit.contain,
    autoPlay: true,
    autoDetectFullscreenAspectRatio: true,
    autoDetectFullscreenDeviceOrientation: true, // portrait video stays upright in fullscreen
    controlsConfiguration: BetterPlayerControlsConfiguration(
      enableQualities: true,
      enablePlaybackSpeed: true,
      enableFullscreen: true,
    ),
  ),
  betterPlayerDataSource: BetterPlayerDataSource(
    BetterPlayerDataSourceType.network,
    video.playbackUrl!,
    videoFormat: Platform.isIOS ? BetterPlayerVideoFormat.hls : BetterPlayerVideoFormat.dash,
  ),
);

var counted = false;
_controller.addEventsListener((event) {
  switch (event.betterPlayerEventType) {
    case BetterPlayerEventType.initialized:
      final ratio = _controller.videoPlayerController?.value.aspectRatio;
      if (ratio != null && ratio > 0) setState(() => _aspectRatio = ratio);   // D17
    case BetterPlayerEventType.play when !counted:
      counted = true;
      context.read<VideoDetailCubit>().recordView();                      // D18
    default:
      break;
  }
});
```

The page wraps the player in an `AspectRatio(aspectRatio: _aspectRatio)`
inside a `ConstrainedBox` capped at 60% of the screen height (§6.6).

On native platforms CloudFront needs nothing from the app: no signing, no
headers, no CORS.

### 8.3 The iOS path (B1, built)

The pipeline side (`IAC/transcoder/transcoder.py`):

1. The existing `dash` muxer runs with `-hls_playlist 1 -hls_master_name
   master.m3u8`. ffmpeg writes `master.m3u8` and one `media_<n>.m3u8` per
   stream next to `manifest.mpd`, all in `<VIDEO_ID>/dash/`. The playlists
   reference the same fMP4 segments (`init-*.m4s`, `chunk-*.m4s`), so there
   is no second encode and storage grows only by the playlists.
2. The upload step sends `.m3u8` files with
   `Content-Type: application/vnd.apple.mpegurl`.
3. The `completed` message carries `hls_manifest_uri` next to
   `manifest_uri`.

The backend side: the poller stores the key from `hls_manifest_uri` in a
new `hls_manifest_s3_key` column (migration
`0002_hls_and_transcode_results`), and the video responses build `hls_url`
from it. The URL is stored from what the transcoder reported, not derived
from the DASH key, so a video transcoded before HLS existed has
`hls_url: null` rather than a URL that 404s.

Spike S2 (§13) now checks this output on a real iPhone rather than proving
the approach.

### 8.4 Portrait video (B8, built)

The ladder's sizes are bounding boxes (1920x1080, 1280x720, 854x480). Each
rendition is scaled to fit its box with the source's aspect ratio kept
(`force_original_aspect_ratio=decrease`, even dimensions), and ffmpeg's
autorotate applies the rotation metadata phones write. A portrait 1080x1920
recording comes out at 608x1080, 404x720, and 270x480, and plays upright.

Two things follow for the app:

- The quality menu's labels come from the stream. For portrait video the
  labels may read by height (1080p) or by width (608p), depending on the
  player; S4 checks which, and the menu is relabelled if it is confusing.
- The player sizes itself to the video (D17, §8.2), so a portrait video
  isn't shrunk to a narrow strip inside a 16:9 box.

---

## 9. Security

- **The app holds no secrets.** The Cognito client secret stays on the
  backend, and the app never calls Cognito directly.
- **Tokens live only in secure storage and in memory.** They never go into
  logs, analytics, or crash reports.
  - `LogInterceptor` exists only in debug builds with `HTTP_LOGS=true`, and
    even then with request and response headers and bodies turned off.
  - Validation errors echo the submitted input, including passwords, so auth
    response bodies are never logged.
- **Presigned URLs are credentials** for their one-hour lifetime. Never log
  them.
- **The S3 client has no auth interceptor**, so the token never reaches S3.
- **Release builds use HTTPS only.** Cleartext is allowed only in debug
  builds, and only for local hosts (§10).
- **Logout** calls `/auth/logout`, which revokes the refresh token and the
  access tokens issued from it. The app clears its storage whatever that call
  returns.
- **First-run wipe** of the Keychain (§5.5).
- **No certificate pinning.** The ALB uses an AWS-issued certificate that
  rotates, and pinning would break the app on rotation.

---

## 10. Platform setup

### Android

- Add `android.permission.INTERNET` to `src/main/AndroidManifest.xml`. The
  Flutter template adds it only to the debug and profile manifests, so a
  release build without it can't reach the network.
- Add a debug-only `network_security_config` that allows cleartext to
  `10.0.2.2`, `localhost`, and your LAN IP. Release builds get none.
- On Android 13 and later, `image_picker` uses the system photo picker and
  needs no storage permission. Check its behaviour on the oldest API level
  you support.
- Check `better_player_plus`'s README for the Gradle and Kotlin versions it
  needs.

### iOS

- In `Info.plist`, set `NSPhotoLibraryUsageDescription`, which
  `image_picker` requires. Add `NSCameraUsageDescription` and
  `NSMicrophoneUsageDescription` only if camera capture is added later.
- For local development only, set `NSAllowsLocalNetworking` to true under
  `NSAppTransportSecurity`. Production uses HTTPS.
- Use the Keychain's default accessibility setting, together with the
  first-run wipe (§5.5).

---

## 11. Local development

**Running the backend locally:** follow Local dev in `backend/AGENTS.md`
(compose Postgres plus uvicorn). A local backend still uses the deployed
Cognito, S3 buckets, and SQS queues. Two consequences:

- **Progress always reads 0.** A workstation can't reach ElastiCache, so a
  local API reports 0% until the video is COMPLETED. Test the progress UI
  against the deployed API.
- **Run only one poller.** Run the local poller, and stop the deployed one
  with `terraform -chdir=backend/terraform apply -var
  poller_desired_count=0`. Otherwise both take messages from the same queue,
  and the deployed poller never finds rows that exist only in your local
  Postgres. Restore the deployed poller afterwards.

`API_BASE_URL` for each target:

| Target | `API_BASE_URL` |
|---|---|
| Android emulator | `http://10.0.2.2:8000` |
| iOS simulator | `http://127.0.0.1:8000` |
| Physical device | `http://<LAN IP>:8000`, with uvicorn started with `--host 0.0.0.0` |
| Deployed | `terraform -chdir=backend/terraform output -raw api_url` |

- **`COOKIE_SECURE` doesn't matter to the app.** It reads the `Set-Cookie`
  headers itself instead of using a cookie jar, so local HTTP works with the
  default `COOKIE_SECURE=true`.
- **Test accounts:** sign up through the app, then confirm without email
  using `aws cognito-idp admin-confirm-sign-up --user-pool-id <pool>
  --username <email>`. This needs operator credentials.
- **Transcodes run for real.** Presigned URLs point at the real buckets, so
  every upload is transcoded in AWS.

---

## 12. Testing

| Level | What is covered | Tools |
|---|---|---|
| Unit | `CookieCapture`: a JWT value, the `""` deletion, `Max-Age`, several headers at once. `ApiException`: both `detail` shapes, the prefix strip, `code` parsing, and a body with no `code` (a non-JSON 502). Models against JSON fixtures captured from a real backend (`test/fixtures/`), including `hls_url` null and set. `Video.playbackUrl` per platform. `VideoUpdate` serialising only changed fields. `Page.hasMore`, duration and view-count formatting, and validators that mirror `schemas.py` | `flutter_test` |
| Interceptor | Concurrent 401s trigger exactly one refresh. A 401 from refresh calls `onSessionExpired` once and clears the tokens. No route in `_skip` triggers a refresh. A 503 passes through untouched | `http_mock_adapter` |
| Cubit | The state sequences for each cubit. `AuthCubit` routing on each login code (`user_not_confirmed`, `password_reset_required`) and the resend and reset states. `UploadVideoCubit` moving through its stages with a fake S3 client. `already_saved` counts as success. Retry resumes from the stage that failed. `VideoDetailCubit.recordView` fires once per page and swallows errors. `update` and `delete` on `MyVideosCubit` and `VideoDetailCubit`, including `video_not_found` | `bloc_test`, `mocktail` |
| Widget | Server field errors appear under the fields. The Resend cooldown. Feed pagination and its end marker. Upload stays disabled until the form is valid. The `PopScope` dialog. The owner menu shows only for the owner. The edit sheet's Save stays disabled until a field changes | `flutter_test` |
| Integration | Against the deployed dev stack with a pre-confirmed user: sign in, load the feed, upload a short MP4 (`integration_test/assets/`), watch My Videos reach Ready, play it and see the count rise, edit its title, then delete it. It takes minutes, so run it on demand | `integration_test` on a device or emulator |
| Manual, per release | Android and iOS, each on a physical device and an emulator or simulator: fresh install, upgrade, logout then sign-in, expired session, resend code, forgot and reset password, and portrait and landscape uploads played inline and in fullscreen | Checklist in `frontend/README.md` |

A debug-only menu item, "Expire access token", overwrites the stored access
token with a bad value. That makes the refresh path easy to test by hand.

CI runs these checks:

- `dart format --output=none --set-exit-if-changed .`
- `flutter analyze`
- `flutter test --coverage`
- `flutter build apk --debug`
- `flutter build ios --no-codesign`, on a macOS runner

---

## 13. Milestones

### M0 — Scaffold and spikes

**Tasks:**

- `flutter create --org <reverse-domain> frontend`.
- Add lints, `env/*.json.example`, `AppConfig`, and CI.

**Spikes:**

- **S1:** play a real `manifest_url` on Android with `better_player_plus`,
  including the quality and speed menus.
- **S2:** play a real `hls_url` on an iPhone with `better_player_plus`,
  including the quality menu. The pipeline already writes HLS (B1), so this
  verifies the output on a device rather than proving the approach.
- **S3:** a presigned PUT from a device with dio streaming, for both content
  types.
- **S4:** upload a portrait phone recording, and check that it plays upright
  on both platforms, that the player reads a 9:16 aspect ratio, and how the
  quality menu labels the renditions (§8.4).

**Exit:** D9, D10, and D17 are confirmed or revised. A problem S2 or S4
finds goes to the pipeline owner as a new B item.

### M1 — Networking and auth

**Tasks:**

- The core layer: `TokenStore`, `CookieCapture`, `AuthInterceptor`,
  `ApiException`, and validators.
- `AuthService`, `SessionCubit`, and `AuthCubit`.
- The Splash, Sign Up, Confirm Sign Up (with Resend), Sign In, Forgot
  Password, and Reset Password pages.
- Logout, and the "Expire access token" debug item.
- Tests.

**Exit:**

- Sign up, confirm with the OTP, and sign in. Relaunching then lands on
  Home.
- An unconfirmed user who lost the code gets a new one and confirms.
- A forgotten password is reset, and the new one signs in.
- A forced 401 is refreshed without the user noticing.
- After logout, a copy of the old access token gets 401.

### M2 — Feed and playback

**Tasks:**

- The models and `VideoService`.
- `FeedCubit`, `HomePage`, and `VideoCard` with the view count.
- `VideoDetailCubit` and `VideoPlayerPage`: DASH on Android, HLS on iOS, a
  player sized to the video, and the view count.

**Exit:**

- A paginated feed with pull-to-refresh.
- Playback on Android and iOS with the quality, speed, and fullscreen
  controls, for landscape and portrait videos.
- Playing a video raises its view count once.
- Leaving the player releases it.

### M3 — Upload and My Videos

**Tasks:**

- `UploadVideoService`, the S3 client, and `UploadVideoCubit`.
- `UploadPage`, including the JPEG re-encode.
- `MyVideosCubit` with progress polling, and `MyVideosPage`.
- The player's processing mode.
- The owner menu, the edit sheet, and delete, on My Videos cards and in the
  player.

**Exit:**

- A 100–500 MB upload shows its progress.
- The video reaches Ready in My Videos without a manual refresh.
- A PUBLIC video then appears in the feed.
- Editing a video's visibility to PRIVATE removes it from the feed;
  deleting it removes it everywhere.

### M4 — Hardening

**Tasks:**

- Persisted `UploadJob`s, with resume and discard.
- Polished error, empty, and skeleton states.
- Accessibility: semantic labels, text scaling up to 200%, and contrast.
- Strings moved to ARB files.
- App icon and splash screen, release signing, and crash reporting that
  never includes tokens.

**Exit:**

- Killing the app mid-upload and relaunching it finishes the job.
- Release builds are on TestFlight and the Play internal testing track.

### M5 (optional) — Web

This needs everything in B9, a JavaScript DASH player behind
`HtmlElementView`, and browser-managed cookies (`withCredentials`) in place
of the header approach.

---

## 14. Backend and pipeline dependencies

B1–B8 are built. The table keeps them, with where each one lives, because
the app's behaviour in §4–§8 depends on them. B9 is the only open item.

| ID | Change | Where | Used by | Status |
|---|---|---|---|---|
| B1 | HLS output: the dash muxer also writes `master.m3u8` and `media_<n>.m3u8` over the same segments, uploaded as `application/vnd.apple.mpegurl`; the `completed` message carries `hls_manifest_uri`; the poller stores `hls_manifest_s3_key`; responses carry `hls_url` | `IAC/transcoder/transcoder.py`; `backend/app/workers/completion_poller.py`, `models.py`, `migrations/versions/0002_hls_and_transcode_results.py`, `routers/video.py`, `schemas.py` | iOS playback (§8.3) | Done. Videos transcoded before it have `hls_url: null` |
| B2 | `POST /auth/resend-otp` (Cognito `ResendConfirmationCode`) | `backend/app/routers/auth.py`; IAM in `backend/terraform/iam.tf` | Confirm Sign Up (§6.2) | Done |
| B3 | `POST /auth/forgot-password` and `/auth/reset-password` (`ForgotPassword`, `ConfirmForgotPassword`) | `backend/app/routers/auth.py`, `schemas.py`; `backend/terraform/iam.tf` | Forgot and Reset Password (§6.8, §6.9) | Done. A reset doesn't revoke existing refresh tokens |
| B4 | A stable `code` next to `detail` in every error body | `backend/app/errors.py` (`APIError`), `main.py` (handlers for validation, 404, 405, database errors), every router | All forms (§4.3) | Done |
| B5 | Late saves: a terminal result with no row is parked in `transcode_results` and applied once the save lands, instead of reaching the DLQ | `backend/app/workers/completion_poller.py`, `models.py`, migration `0002` | Upload (§7.4) | Done. Parked results are pruned after 7 days |
| B6 | `PATCH /video/{id}` (title, description, visibility) and `DELETE /video/{id}` (row, cache key, then the S3 objects in the background), owner only | `backend/app/routers/video.py`, `schemas.py` (`UpdateVideoRequest`), `cache.py` (`drop_video`); `backend/terraform/iam.tf` (S3 delete), `ecs.tf` (`S3_PROCESSED_BUCKET`) | Player and My Videos (§6.6, §6.7) | Done. CloudFront may serve a deleted video's segments until its cache expires |
| B7 | `POST /video/{id}/view`: atomic `views_count + 1`, 204; `video_not_ready` unless COMPLETED | `backend/app/routers/video.py` | Feed, player (§6.4, §6.6) | Done. No per-viewer dedupe; the cached detail lags by up to 1 h |
| B8 | A ladder of bounding boxes that keeps the source's aspect ratio, with rotation metadata applied | `IAC/transcoder/transcoder.py` (`LADDER`) | Playback (§8.4) | Done |
| B9 | Web only: `cors_origins`, `cookie_samesite = "none"`, `thumbnails_cors_origins`. Note that a browser never sends the refresh cookie to `/auth/logout` (its path is `/auth/refresh`), so logout on web doesn't revoke it | `backend/terraform` tfvars, `auth.py` | M5 | Open. Not needed until the web target starts |

---

## 15. Risks and open questions

### Risks

- **R1 — iOS playback of the HLS output is unproven on a device.** B1 is
  built and checked with ffmpeg, but no iPhone has played it yet. Mitigation:
  S2 runs in M0, before any iOS work depends on it.
- **R2 — `better_player_plus` may not build on the Flutter version current
  at scaffold time.** The fallback is the official `video_player`, which
  plays DASH on Android through ExoPlayer and HLS on iOS, with a custom speed
  menu. It exposes no track selection, so the quality menu would be lost.
  `media_kit` is the other candidate to evaluate.
- **R3 — Large uploads on unreliable networks.** A failed single PUT starts
  again from zero. S3 multipart upload would need new backend endpoints
  (create the upload, sign each part, complete it). Revisit if uploads over
  roughly 500 MB become common.
- **R4 — Going to the background kills uploads on iOS.** See §7.6.
- **R5 — Users sign in again every 5 days.** Refresh tokens don't rotate,
  and the cookie `Max-Age` is 5 days. If that's too short, raise
  `refresh_cookie_max_age`, or enable rotation on the Cognito app client (the
  backend already stores a rotated token).
- **R6 — A local backend races the deployed poller.** See §11.
- **R7 — View counts are easy to inflate.** The backend counts every
  `POST /video/{id}/view` with no per-viewer dedupe, and the endpoint needs
  no auth. The app sends one per page (D18), but a script can send many.
  Fine for v1; dedupe would be a backend change.
- **R8 — Deleting a video mid-transcode leaves output behind.** The row and
  the objects present at delete time go, but a transcoder still running
  keeps writing to the processed bucket. The app allows it anyway; the cost
  is storage, not a visible bug.

### Open questions

Each one has a default already chosen; change it if it's wrong.

- **Q1 — Anonymous browsing?** The feed and public videos need no auth, but
  the plan keeps the spec's login gate. Opening them up would be a small
  change to the root switch.
- **Q2 — Default visibility on upload:** Private (the spec), or Public (the
  database default)? The plan uses Private.
- **Q3 — Upload size cap:** 2 GiB (`MAX_UPLOAD_BYTES`).
- **Q4 — Web target:** deferred to M5.
- **Q5 — App name and bundle ID:** "Video Stream" and `<reverse-domain>.videostream`.
- **Q6 — Do owners' own plays count?** The plan counts them, as YouTube
  does. Skipping them is a one-line check in `recordView`.
- **Q7 — Should a FAILED video offer "Upload again"?** The plan offers only
  Delete. Re-uploading with the same title and thumbnail would need the
  local files, which are deleted after a successful save.

---

## Appendix — Sign-in and refresh sequence

```
App                                  API                               Cognito
 |-- POST /auth/login {email,pw} ---->|-- InitiateAuth ------------------>|
 |<-- 200 + Set-Cookie access, refresh|<-- tokens ------------------------|
 |   CookieCapture -> TokenStore      |                                   |
 |-- GET /auth/me (Bearer access) --->|-- GetUser ----------------------->|
 |<-- 200 UserProfile ----------------|                                   |
 |   SessionCubit.signedIn(user)      |                                   |
 ...  one hour later  ...
 |-- GET /video/mine (Bearer old) --->|-- GetUser -> NotAuthorized ------>|
 |<-- 401 ----------------------------|                                   |
 |   AuthInterceptor (queued)         |                                   |
 |-- POST /auth/refresh (bare, Cookie: refresh_token) ->|-- GetTokensFromRefreshToken ->|
 |<-- 200 + Set-Cookie access --------|                                   |
 |-- GET /video/mine (bare, Bearer new) ->|                               |
 |<-- 200 ----------------------------|                                   |
```
