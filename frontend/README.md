# ytp_app — Flutter web client

The web app for the video platform in this repo: browse and search public
videos, watch them (HLS in the browser), sign up / sign in, upload from the
browser, and manage your videos. Its look follows the Figma "YouTube UI Clone"
mockups (home grid, watch page, channel page; dark theme). The backend
contract is `../backend/app/`.

> **First time?** [`SETUP.md`](SETUP.md) covers installing Flutter, running
> against a local or deployed backend, building, and hosting.

## Run

```bash
cd frontend
flutter pub get
flutter run -d chrome --web-hostname 127.0.0.1 --web-port 8090 \
  --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

The API must list the app's origin in `CORS_ORIGINS`
(`http://127.0.0.1:8090` here). Leave `API_BASE_URL` empty when the app is
served from the API's own origin; it then calls the page's origin.

## Checks

```bash
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test                      # unit + widget tests, on the VM
../scripts/run_pipeline.sh        # backend + browser E2E (see SETUP.md)
```

## Pages

| URL | Page | Backend |
|---|---|---|
| `/` | Home: chip bar (All, Most viewed, one per creator) over the video grid | `GET /video/feed?sort=`, `GET /video/channel/{id}` |
| `/results?search_query=` | Search results, newest or most viewed | `GET /video/search` |
| `/watch?v=` | Player, title, views/date, share, owner edit/delete, channel row, description, up next (All / From creator); signed in, resumes where you stopped and records progress | `GET /video/{id}`, `POST /video/{id}/view`, `PATCH`/`DELETE /video/{id}`, `GET /video/{id}/progress`, `GET /history/positions`, `POST /history/progress` |
| `/channel/:id`, `/channel/:id/videos` | Channel: header with HOME/VIDEOS tabs, featured upload, shelves | `GET /video/channel/{id}` |
| `/my-videos` | Your videos (signed in): every status, live progress, edit, delete | `GET /video/mine`, `GET /video/{id}/progress` |
| `/upload` | Upload (signed in): drop or pick an MP4, details, thumbnail captured from the video or picked | `GET /upload/video/url{,/thumbnail}`, presigned PUTs, `POST /upload/video/save` |
| `/feed/history` | Watch history (signed in): newest first by day, remove (with undo), clear all | `GET /history`, `DELETE /history{,/{id}}` |
| `/signin`, `/signup`, `/verify`, `/forgot-password`, `/reset-password` | Auth | `/auth/*` |

Browsing works signed out. Upload, Your videos, and History send a
signed-out visitor to Sign in and back afterwards. Signed in, every
thumbnail carries a red bar for how much of it you watched
(`GET /history/positions`, one request per screenful).

## Layout

```
lib/
├── main.dart                 path URLs, crash reporting, runApp
├── app/                      YtpApp (providers), router (go_router), routes
├── core/                     config, theme (Figma tokens), Dio client,
│                             401-refresh interceptor, ApiException,
│                             validators, formatters, crash scrubbing
├── platform/                 browser APIs behind interfaces: file picking,
│                             drag-and-drop, frame capture, JPEG encoding,
│                             presigned PUTs (XHR), fullscreen, leave warning,
│                             localStorage, page hide/show, keepalive POST;
│                             the <video> player with hls.js / dash.js
├── models/                   UserProfile, Video/Creator, ChannelListing,
│                             PageResult, Progress, SavedVideo, WatchProgress
├── services/                 AuthService, VideoService, UploadVideoService,
│                             watch history: HistoryService, HistorySync,
│                             HistoryOutbox, WatchProgressStore,
│                             ProgressTracker
├── cubits/                   session, auth, feed (+search), channel,
│                             my_videos, video_detail, upload_video, history
├── pages/                    shell (masthead, guide), home, search, watch,
│                             channel, your_videos, upload, history,
│                             not_found, auth/*
└── widgets/                  grid card, list tile, thumbnail, chip bar,
                              player controls, avatar, logo, dialogs, ...
web/                          index.html, manifest, icons, vendor/ (hls.js,
                              dash.js)
test/                         unit, cubit, interceptor, router and widget
                              tests (the whole app over mocked services)
integration_test/             browser E2E against the seeded test backend
```

## Notes

- Session: the browser stores the HttpOnly `access_token` (path `/`) and
  `refresh_token` (path `/auth`) cookies. On a 401 the interceptor calls
  `/auth/refresh` once (shared by every request that failed together) and
  retries; while signed in the session cubit renews the access cookie every
  50 minutes, before Cognito's one-hour token runs out.
- Playback: HLS through hls.js (Chrome, Edge, Firefox) or natively (Safari);
  DASH through dash.js only for videos transcoded before the pipeline wrote
  HLS. The libraries load on the first watch page, from `web/vendor/`.
- Uploads stream the picked `File` straight from the browser to the
  presigned S3 URL (no copy into Dart memory). The upload belongs to the app,
  not the page: it keeps going while you browse, the masthead's upload
  button shows its progress, and closing the tab asks first.
- Avatars are the creator's initial on a colour derived from their id: the
  backend has no profile pictures.
- Watch history (`../docs/plans/watch-history-plan.md`): the watch page
  reports the position every 15 s while playing and on pause, seek, end,
  leaving, and hiding the tab, once 5 s have been played. Reports wait in
  `localStorage` (`ytp.history.<userId>.<videoId>`) until the server has
  them, so closing the tab loses nothing; the server keeps the latest
  observation, so browsers never overwrite newer progress. Signing out sends
  what is waiting and then deletes it.
- Not built because the backend has no API for them: likes, comments,
  subscriptions, notifications. The mockup shows these; the app leaves them
  out rather than show controls that do nothing.
