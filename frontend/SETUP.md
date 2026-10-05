# Setup: install Flutter, get dependencies, run the app locally

Step-by-step for getting `frontend/` running on an emulator, simulator, or
phone. For what the app does and how it is laid out, see `README.md` and
`PLAN.md`.

The versions below are the ones this project was built and tested with. Newer
stable releases should work; if a plugin fails to build, come back to these.

| Tool | Version | Needed for |
|---|---|---|
| Flutter (stable) | 3.47.x (Dart ≥ 3.13.5, see `pubspec.yaml`) | everything |
| JDK | 17 | Android builds |
| Android Studio + Android SDK | current stable; SDK platform for API 24+ | Android |
| Xcode + CocoaPods | Xcode 15+; iOS 15+ simulator or device | iOS (macOS only) |

You only need the Android *or* the iOS toolchain. iOS builds need macOS.

---

## 1. Install Flutter

**macOS / Linux**

```bash
# Pick an install location and clone the stable channel
git clone https://github.com/flutter/flutter.git -b stable ~/development/flutter
echo 'export PATH="$HOME/development/flutter/bin:$PATH"' >> ~/.zshrc   # or ~/.bashrc
source ~/.zshrc
```

(On macOS, `brew install --cask flutter` also works.)

**Windows**: follow <https://docs.flutter.dev/install/windows> and add
`flutter\bin` to `PATH`.

Check the install and see what is still missing:

```bash
flutter --version
flutter doctor
```

`flutter doctor` lists each missing piece with the fix. Work through the items
for the platform you are targeting:

- **Android**: install Android Studio, open *Settings → Languages & Frameworks
  → Android SDK*, install an SDK platform (API 34+) plus *Command-line Tools*,
  then accept licences:

  ```bash
  flutter doctor --android-licenses
  ```

  Create an emulator in *Device Manager* (a Pixel image with API 34+), or
  enable *Developer options → USB debugging* on a phone.

- **iOS** (macOS): install Xcode from the App Store, then

  ```bash
  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -runFirstLaunch
  sudo gem install cocoapods        # or: brew install cocoapods
  open -a Simulator
  ```

  Running on a physical iPhone also needs a (free) Apple developer team set
  under *Runner → Signing & Capabilities* in `ios/Runner.xcworkspace`.

## 2. Get the code and install dependencies

```bash
git clone https://github.com/ritwik-jha/yt-clone.git
cd yt-clone
git checkout feature/flutter-frontend     # until it is merged to main
cd frontend
flutter pub get
```

`flutter pub get` downloads every package in `pubspec.yaml` and uses the
committed `pubspec.lock`, so everyone gets the same versions. On iOS, CocoaPods
runs automatically on the first `flutter run` (or run `cd ios && pod install`).

Sanity check before running anything:

```bash
flutter analyze
flutter test
```

Both should finish clean. `flutter test` needs no device and no backend.

## 3. Tell the app where the backend is

The app talks to the FastAPI backend in `../backend`. It needs the backend's
base URL, and **you can supply it in any of three ways**. In a debug build they
are checked in this order:

1. **Typed into the app (dev builds only).** Tap the server icon
   (<kbd>⛁</kbd> `dns`) on the sign-in / sign-up screens, or *Account → Backend
   server* on Home, and enter a URL. It is saved on the device, survives
   restarts, and applies immediately (changing it signs you out, because tokens
   from one backend mean nothing to another). If neither of the other two
   options is set, the app opens on a "Connect to a server" screen first.
2. **A build-time default** from an env file.
3. A one-off `--dart-define` on the command line.

Options 2 and 3 set `API_BASE_URL`. For the env file:

```bash
cp env/dev.json.example env/dev.json
# edit env/dev.json and set API_BASE_URL
flutter run --dart-define-from-file=env/dev.json
```

or, with no file:

```bash
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

`env/*.json` is gitignored; only the `*.example` files are committed. A URL typed
into the app overrides the build-time default, and *Use build default* in the
server dialog goes back to it.

Which URL to use:

| Where the app runs | `API_BASE_URL` |
|---|---|
| Android emulator | `http://10.0.2.2:8000` (the emulator's alias for your computer's `localhost`) |
| iOS simulator | `http://127.0.0.1:8000` |
| Physical phone (same Wi-Fi) | `http://<your computer's LAN IP>:8000`, and start uvicorn with `--host 0.0.0.0` |
| Deployed backend | `terraform -chdir=backend/terraform output -raw api_url` (looks like `https://<name>.ecs.<region>.on.aws`) |

The URL may be entered with or without `http://` and with or without a trailing
slash; the app cleans it up. Cleartext `http://` works in **debug builds only**
(Android's debug network-security config, iOS `NSAllowsLocalNetworking`);
release builds are HTTPS-only and refuse to start without `API_BASE_URL`.

> Debug builds allow the in-app URL field by default. To force it on or off
> elsewhere, pass `--dart-define=ALLOW_SERVER_OVERRIDE=true|false`.

## 4. Run the app

```bash
flutter devices                                   # list emulators / simulators / phones
flutter run --dart-define-from-file=env/dev.json  # pick a device when asked
flutter run -d <device-id> --dart-define-from-file=env/dev.json
```

While it runs: `r` hot-reloads, `R` hot-restarts, `q` quits.

If you skipped the env file, plain `flutter run` works too and the app will
ask for the server URL on first launch.

### Running a backend locally (optional)

If you don't have a deployed stack, run the API on your machine
(details in `../backend/README.md`, *Local development*):

```bash
cd ../backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env              # fill in the Cognito / SQS / bucket values
docker compose up -d postgres redis
alembic upgrade head
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

Limits of a local backend (it still uses the **deployed** Cognito, S3 buckets,
and SQS queues):

- Upload progress reads `0` until a video is COMPLETED, because a laptop can't
  reach the pipeline's ElastiCache Redis.
- Run only one completion poller. If you run it locally, scale the deployed one
  to zero first (`terraform -chdir=backend/terraform apply -var
  poller_desired_count=0`), otherwise both consume the same queue.
- Uploads really are transcoded in AWS.

### A test account

Sign up in the app, then skip the email step by confirming the user directly
(needs AWS operator credentials):

```bash
aws cognito-idp admin-confirm-sign-up --user-pool-id <pool-id> --username <email>
```

Or use the real flow: the verification code arrives by email and goes into the
*Confirm Sign Up* screen.

## 5. Useful dev features

- **Backend server** (above): change the API URL without rebuilding.
- **Account → Expire access token** (debug builds only): corrupts the stored
  access token, then reloads the feed, so you can watch the 401 → silent refresh
  path work.
- **Upload recovery**: kill the app mid-upload and relaunch. A finished-but-unsaved
  upload is saved automatically; an unfinished one shows an "Unfinished upload"
  banner on Home with *Resume* and *Discard*.
- `HTTP_LOGS=true` (in the env file or `--dart-define`) adds a debug-only request
  log. Headers and bodies stay off so tokens and passwords never reach the console.

## 6. Tests and checks

```bash
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test                      # unit, cubit, interceptor, widget tests
```

End-to-end smoke test against a real backend (needs a device or emulator and an
existing, confirmed account):

```bash
flutter test integration_test \
  --dart-define-from-file=env/dev.json \
  --dart-define=TEST_EMAIL=you@example.com \
  --dart-define=TEST_PASSWORD='Passw0rd!'
```

Without `TEST_EMAIL`/`TEST_PASSWORD` the test is skipped. It signs in, loads the
feed, opens a video, and logs out. Picking and uploading a file uses the OS
picker, which Flutter can't drive, so that stays on the manual checklist
(upload a short MP4 → watch it go Pending → Processing → Ready in *My videos* →
play it → edit → delete).

### Web build and the local E2E pipeline

The app also builds for the web, which is how CI-style end-to-end runs work
without a device. `scripts/run_pipeline.sh` at the repo root seeds a SQLite
test database, starts the backend on it with fake Cognito/S3/Redis, and runs
`integration_test/seeded_flow_test.dart` in headless Chrome (sign up → confirm
→ sign in → feed → video page → *My videos* → edit → log out). See *Testing*
in `../backend/README.md` for what it needs and how to run each step alone.

On the web the session lives in HttpOnly cookies the browser manages, so
serve the app from the same host as the API (`127.0.0.1` for both, ports may
differ) or the browser won't send them. The web build is for testing and
browsing only:

- Playback shows a placeholder: `better_player_plus` has no web support.
- Upload and resuming uploads need the native pickers and file system.
- Log out clears the cookies but doesn't revoke the refresh token, because
  the browser only sends that cookie to `/auth/refresh`.

## 7. Building

```bash
# Android
flutter build apk --debug   --dart-define-from-file=env/dev.json
flutter build apk --release --dart-define-from-file=env/prod.json
flutter build appbundle --release --dart-define-from-file=env/prod.json

# iOS (macOS)
flutter build ios --no-codesign --dart-define-from-file=env/dev.json
```

Release builds must be built with an HTTPS `API_BASE_URL` (`env/prod.json`).

**Android release signing**: copy `android/key.properties.example` to
`android/key.properties` and point it at your keystore. Both the file and
`*.jks` are gitignored. Without it, release builds are signed with the debug key
so `flutter run --release` still works locally; don't ship those.

**App icon and splash** come from `assets/branding/`. After changing the images:

```bash
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `flutter doctor` shows Android licence errors | `flutter doctor --android-licenses` |
| App starts on "Connect to a server" | No `API_BASE_URL` was passed. Enter the URL, or run with `--dart-define-from-file=env/dev.json` |
| "Can't reach the server" on Android emulator | Use `http://10.0.2.2:8000`, not `localhost`/`127.0.0.1` (that is the emulator itself) |
| "Can't reach the server" on a real phone | Phone and computer on the same Wi-Fi; uvicorn started with `--host 0.0.0.0`; firewall allows port 8000; use the computer's LAN IP |
| `Cleartext HTTP traffic not permitted` | You're on a release build. Use HTTPS, or run a debug build |
| Signed in, but immediately back at Sign In | The server didn't return `Set-Cookie` tokens (a proxy stripped them), or the backend and app point at different Cognito pools |
| Upload fails with 403 / `SignatureDoesNotMatch` | Presigned URLs are signed for exactly `video/mp4` and `image/jpeg`; the app sends those, so check the device clock and that the URL wasn't altered by a proxy |
| Video won't play on iPhone | iOS plays HLS only. Videos transcoded before HLS output existed have no `hls_url`; re-upload them |
| `pod install` fails | `cd ios && pod repo update && pod install` |
| Odd build errors after switching Flutter versions | `flutter clean && flutter pub get` |
