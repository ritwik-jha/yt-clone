# ytp_app — Flutter client

A YouTube-style (dark theme) mobile client for the video platform in this
repo. The plan is in [`PLAN.md`](PLAN.md); screens come from
[`../docs/frontend-screens-spec.md`](../docs/frontend-screens-spec.md); the
backend contract is `../backend/app/`. Where they disagree, the backend wins
(PLAN §3).

Targets: Android and iOS. Flutter web is out of scope for v1.

> **First time?** See [`SETUP.md`](SETUP.md) for installing Flutter, fetching
> dependencies, and running on an emulator/simulator/phone.

## Run

```bash
cd frontend
flutter pub get
cp env/dev.json.example env/dev.json        # set API_BASE_URL
flutter run --dart-define-from-file=env/dev.json
```

`API_BASE_URL` per target (PLAN §11): Android emulator `http://10.0.2.2:8000`,
iOS simulator `http://127.0.0.1:8000`, deployed API
`terraform -chdir=../backend/terraform output -raw api_url`. `env/*.json` is
gitignored; only the `*.example` files are committed.

**The backend URL can also be entered in the app** (debug builds only): the
server icon on the sign-in/sign-up screens, or *Account → Backend server* on
Home. It is saved on the device and overrides the build-time default; with no
default at all, the app opens on a "Connect to a server" screen. Release builds
ignore this and require `API_BASE_URL` (`main()` fails fast without it).

## Checks (same as CI)

```bash
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test
```

On-demand end-to-end smoke test (needs a device/emulator and a confirmed
account): see `integration_test/app_test.dart` and SETUP.md §6.

## Layout

```
lib/
├── main.dart                 providers, root switch on SessionCubit
├── core/                     config, theme, Dio clients, token store,
│                             cookie capture, 401-refresh interceptor,
│                             server URL settings, crash scrubbing,
│                             ApiException, validators, formatters
├── models/                   UserProfile, Video/Creator, PageResult, Progress
├── services/                 AuthService, VideoService, UploadVideoService,
│                             UploadJobStore (resumable uploads)
├── cubits/                   session, auth, feed, my_videos, video_detail,
│                             upload_video, pending_uploads
├── pages/                    splash, server_setup, auth/*, home, upload,
│                             resume_upload, video_player, my_videos
└── widgets/                  video_card, status_chip, error_view, owner_menu,
                              edit_video_sheet, resend_code_button, auth_scaffold
test/                         unit, cubit, interceptor and widget tests
integration_test/             on-demand end-to-end smoke test
assets/branding/              app icon + splash source images
```

## Implementation status (against PLAN §13)

| Milestone | State |
|---|---|
| M0 scaffold (lints, env files, `AppConfig`, CI) | Done |
| M0 spikes S1–S4 (real DASH/HLS playback, S3 PUT, portrait video on a device) | **Not run** — need a device and the deployed stack |
| M1 networking + auth (token store, cookie capture, refresh interceptor, sign up / confirm + resend / sign in / forgot + reset, logout, debug "Expire access token") | Implemented, unit/widget tested |
| M2 feed + playback (paginated feed, player with D10/D17/D18) | Implemented. Player itself is untested on a device |
| M3 upload + My Videos (streamed PUTs, staged retry, polling, edit/delete) | Implemented. Not run against a real backend |
| M4 persisted upload jobs (resume / discard banner, save-on-launch) | Implemented, unit tested |
| M4 skeleton loading, semantic labels, 200% text-scale checks | Implemented for the feed, My Videos, cards, and edit sheet |
| M4 app icon + native splash, Android release-signing hook, scrubbed crash-reporting seam (`core/crash_reporter.dart`) | Implemented. No crash-reporting vendor is wired in |
| Backend URL entered in the app (dev builds) | Implemented |
| `integration_test/` smoke test | Written; not run (needs a device and a backend) |
| M4 strings moved to ARB / localisation | **Not done** — strings are still inline |
| M4 release builds on TestFlight / Play internal track | **Not done** — needs signing identities and store accounts |
| Full accessibility audit with TalkBack / VoiceOver | **Not done** — only automated checks so far |

## Notes

- Auth uses `Authorization: Bearer` for the access token and an explicit
  `Cookie: refresh_token=…` header only to `/auth/refresh` and `/auth/logout`;
  `Set-Cookie` headers are read by `CookieCapture`, so there is no cookie jar.
- The S3 `Dio` instance has no interceptors, so the API token never reaches S3.
- `PageResult<T>` is the plan's `Page<T>`, renamed to avoid Flutter's `Page`.
- Android: `INTERNET` is declared in the main manifest; cleartext HTTP is
  allowed only in the debug `network_security_config`. iOS:
  `NSPhotoLibraryUsageDescription` set, `NSAllowsLocalNetworking` for local dev.
