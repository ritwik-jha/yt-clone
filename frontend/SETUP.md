# Setup: install Flutter, run the web app, build and host it

For what the app does and how it is laid out, see `README.md`.

| Tool | Version | Needed for |
|---|---|---|
| Flutter (stable) | 3.47.x (Dart ≥ 3.13.5, see `pubspec.yaml`) | everything |
| Chrome or Chromium | any current | `flutter run -d chrome`, the E2E |
| ChromeDriver | same major version as the Chrome above | the E2E only |
| Python 3.11+ | | the local backend and its tests |

---

## 1. Install Flutter

```bash
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
export PATH="$HOME/flutter/bin:$PATH"     # add to your shell profile
flutter --version
flutter config --enable-web
flutter doctor                            # only the Chrome line matters here
```

If Chrome isn't where Flutter looks, point at it:
`export CHROME_EXECUTABLE=/path/to/chrome`.

## 2. Get the code and dependencies

```bash
cd frontend
flutter pub get
```

## 3. Run against a backend

### a. The seeded local backend (no AWS needed)

The backend's test server runs the real API on a SQLite file, with Cognito,
S3, and Redis replaced by in-process fakes. Every account's password is
`Passw0rd!` and every verification code is `123456`; the seeded users are
`alice@example.com` and `bob@example.com`.

```bash
cd ../backend
pip install -r requirements.txt -r requirements-dev.txt
python scripts/seed_sqlite.py                      # writes backend/test.db
set -a; . tests/support/test.env; set +a
uvicorn tests.support.server:app --host 127.0.0.1 --port 8000
```

In another terminal:

```bash
cd frontend
flutter run -d chrome --web-hostname 127.0.0.1 --web-port 8090 \
  --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

Use `127.0.0.1` for both, never `localhost` for one of them: the auth cookies
are `SameSite=Lax`, so the browser only sends them when the app and the API
are on the same site. `test.env` already allows the app's origin
(`CORS_ORIGINS=http://127.0.0.1:8090,...`).

Seeded videos point at made-up CDN hosts, so they show placeholders and the
player reports it can't play them. Uploads work: the test server keeps the
presigned PUTs in memory, and the video then waits in *Your videos* as
Pending (nothing transcodes locally).

### b. A deployed backend

```bash
cp env/dev.json.example env/dev.json   # set API_BASE_URL to the API's https URL
flutter run -d chrome --web-port 8090 --dart-define-from-file=env/dev.json
```

The API's `CORS_ORIGINS` must include `http://localhost:8090` (or whatever
origin you serve on), and because `localhost` and the API are different sites
its cookies must be `SameSite=None; Secure` (`cookie_samesite = "none"` in
`backend/terraform`). See §5 for why same-origin hosting avoids both.

## 4. Tests

```bash
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test
```

`flutter test` runs on the Dart VM: the browser layer (`lib/platform/*_web.dart`)
is swapped for stubs, and widget tests drive the whole app (router, shell,
pages) over mocked services.

The browser end-to-end test, `integration_test/seeded_flow_test.dart`, runs in
headless Chrome against the seeded backend: browse signed out, sign up,
confirm, sign in, search, watch, open a channel, sign out and in, *Your
videos*, edit a title, upload from the browser, and sign out. The pipeline
script at the repo root does everything (seed, start the backend, backend
tests, Flutter checks, web build, ChromeDriver, E2E, cleanup):

```bash
PATH=/path/to/flutter/bin:$PATH \
CHROME_EXECUTABLE=/path/to/chrome \
CHROMEDRIVER=/path/to/chromedriver \
../scripts/run_pipeline.sh            # --only 4 for just the E2E
```

## 5. Build and host

```bash
flutter build web --release --dart-define-from-file=env/prod.json
# output: build/web/  (static files; upload them to any static host)
```

Two things every host must do:

- **Answer unknown paths with `index.html`** (status 200). The app uses real
  paths (`/watch?v=...`), so a reload or a shared link asks the host for
  `/watch`. On CloudFront + S3: custom error responses for 403 and 404 →
  `/index.html`, 200.
- **Serve `web/vendor/`** along with the rest (it holds the player libraries).

Then pick one of:

**Same origin (recommended).** Put the app and the API behind one domain,
e.g. a CloudFront distribution whose `/auth/*`, `/video/*`, `/upload/*`, and
`/healthz` behaviours go to the API (no caching, all methods, forward cookies
and query strings) and whose default behaviour serves `build/web` from S3.
Build with `API_BASE_URL` empty (`env/prod.json.example`): the app then calls
its own origin. The cookies are first-party, `SameSite=Lax` works, and the
API's `CORS_ORIGINS` stays empty (no cross-origin access at all).

**Separate origins.** The app on one domain, the API on another (for example
the ECS Express Mode endpoint). Build with `API_BASE_URL=https://<api>`, and
on the backend set `cors_origins = ["https://<app origin>"]`,
`cookie_samesite = "none"`, and `cookie_secure = true`. Browsers that block
third-party cookies (Safari, Chrome with that setting) won't keep the session
in this setup, which is why same-origin is the default advice.

Either way the media CORS is already in place: the raw upload bucket accepts
browser PUTs from any origin (`IAC/terraform/storage.tf`), the thumbnails
bucket from `thumbnails_cors_origins`, and both CloudFront distributions add
`Access-Control-Allow-Origin` (hls.js fetches playlists and segments with
XHR).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Signed in, but every call is anonymous / back at Sign in | The browser isn't sending the cookies: app and API on different sites with `SameSite=Lax`, or `COOKIE_SECURE=true` over plain http. See §3 and §5 |
| `blocked by CORS policy` in the console | Add the app's exact origin (scheme, host, port) to the API's `CORS_ORIGINS` |
| A reload shows the host's 404 page | The host doesn't fall back to `index.html` (§5) |
| "This video can't be played right now" | The stream failed to load: check the CloudFront URL and its CORS headers in the network tab. Videos still transcoding never reach the player |
| Upload fails with 403 | The presigned URL expired (the app fetches a new one once) or a proxy changed the `Content-Type`; it must be exactly `video/mp4` / `image/jpeg` |
| Upload picker greys out the file | Only MP4 is accepted (the pipeline's raw bucket only fires on `.mp4` keys) |
| E2E: `Chrome N needs chromedriver N` | Install the ChromeDriver whose major version matches `chrome --version` |
| Odd build errors after switching Flutter versions | `flutter clean && flutter pub get` |
