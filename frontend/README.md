# ytp_app — Flutter client

A YouTube-style (dark theme) mobile client for the video platform in this
repo. The plan is in [`PLAN.md`](PLAN.md); screens come from
[`../docs/frontend-screens-spec.md`](../docs/frontend-screens-spec.md); the
backend contract is `../backend/app/`. Where they disagree, the backend wins
(PLAN §3).

Targets: Android and iOS. Flutter web is out of scope for v1.

## Run

```bash
cd frontend
flutter pub get
cp env/dev.json.example env/dev.json        # set API_BASE_URL
flutter run --dart-define-from-file=env/dev.json
```

`API_BASE_URL` per target (PLAN §11): Android emulator `http://10.0.2.2:8000`,
iOS simulator `http://127.0.0.1:8000`, deployed API
`terraform -chdir=../backend/terraform output -raw api_url`. `main()` fails fast
when it is empty. `env/*.json` is gitignored; only the `*.example` files are
committed.

## Checks (same as CI)

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

## Layout

```
lib/
├── main.dart                 providers, root switch on SessionCubit
├── core/                     config, theme, Dio clients, token store,
│                             cookie capture, 401-refresh interceptor,
│                             ApiException, validators, formatters
├── models/                   UserProfile, Video/Creator, PageResult, Progress
├── services/                 AuthService, VideoService, UploadVideoService
├── cubits/                   session, auth, feed, my_videos,
│                             video_detail, upload_video
├── pages/                    splash, auth/*, home, upload, video_player, my_videos
└── widgets/                  video_card, status_chip, error_view, owner_menu,
                              edit_video_sheet, resend_code_button, auth_scaffold
test/                         unit, cubit, interceptor and widget tests
```

## Implementation status (against PLAN §13)

| Milestone | State |
|---|---|
| M0 scaffold (lints, env files, `AppConfig`, CI) | Done |
| M0 spikes S1–S4 (real DASH/HLS playback, S3 PUT, portrait video on a device) | **Not run** — need a device and the deployed stack |
| M1 networking + auth (token store, cookie capture, refresh interceptor, sign up / confirm + resend / sign in / forgot + reset, logout) | Implemented, unit/widget tested |
| M2 feed + playback (paginated feed, player with D10/D17/D18) | Implemented. Player itself is untested on a device |
| M3 upload + My Videos (streamed PUTs, staged retry, polling, edit/delete) | Implemented. Not run against a real backend |
| M4 hardening (persisted upload jobs, ARB strings, a11y pass, icons, signing) | Not started |

Not yet built from the plan: the debug "Expire access token" menu item,
`flutter_image_compress`/`image_picker` behaviour on real devices, the
"Unfinished upload" banner (M4), and integration tests.

## Notes

- Auth uses `Authorization: Bearer` for the access token and an explicit
  `Cookie: refresh_token=…` header only to `/auth/refresh` and `/auth/logout`;
  `Set-Cookie` headers are read by `CookieCapture`, so there is no cookie jar.
- The S3 `Dio` instance has no interceptors, so the API token never reaches S3.
- `PageResult<T>` is the plan's `Page<T>`, renamed to avoid Flutter's `Page`.
- Android: `INTERNET` is declared in the main manifest; cleartext HTTP is
  allowed only in the debug `network_security_config`. iOS:
  `NSPhotoLibraryUsageDescription` set, `NSAllowsLocalNetworking` for local dev.
