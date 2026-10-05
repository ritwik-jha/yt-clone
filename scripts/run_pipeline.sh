#!/usr/bin/env bash
# Verification pipeline: backend sanity, frontend sanity, API integration,
# and a Flutter web E2E run in headless Chrome. Everything runs against a
# throwaway SQLite database (backend/test.db) seeded from
# backend/tests/support/seed_data.py, with Cognito, S3 and Redis replaced by
# in-process fakes (backend/tests/support/server.py). No AWS access needed.
#
#   scripts/run_pipeline.sh            # all four steps
#   scripts/run_pipeline.sh --from 3   # resume at a step after fixing it
#   scripts/run_pipeline.sh --only 4
#
# Each step that talks to the backend reseeds the database and restarts the
# server first, so steps never see each other's writes.
#
# Needs: python3 with backend/requirements-dev.txt, flutter, a Chrome or
# Chromium, and a chromedriver with the same major version. Override with
#   FLUTTER=/path/to/flutter CHROME_EXECUTABLE=/path/to/chrome
#   CHROMEDRIVER=/path/to/chromedriver PYTHON=python3
#   API_PORT=8000 WEB_PORT=8090 DRIVER_PORT=4444 KEEP_DB=1
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND="$ROOT/backend"
FRONTEND="$ROOT/frontend"

PYTHON="${PYTHON:-python3}"
FLUTTER="${FLUTTER:-flutter}"
CHROMEDRIVER="${CHROMEDRIVER:-chromedriver}"
API_PORT="${API_PORT:-8000}"
WEB_PORT="${WEB_PORT:-8090}"
DRIVER_PORT="${DRIVER_PORT:-4444}"
# 127.0.0.1 for both the API and the web app: same site, so the browser
# sends the SameSite=Lax auth cookies on the app's API calls.
API_URL="http://127.0.0.1:$API_PORT"
DB="$BACKEND/test.db"
LOGS="$(mktemp -d "${TMPDIR:-/tmp}/ytp-pipeline.XXXXXX")"

FROM=1
ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

BACKEND_PID=""
DRIVER_PID=""

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mFAILED: %s\033[0m\nLogs: %s\n' "$*" "$LOGS" >&2; exit 1; }

stop_backend() {
  if [[ -n "$BACKEND_PID" ]]; then
    kill "$BACKEND_PID" 2>/dev/null || true
    wait "$BACKEND_PID" 2>/dev/null || true
    BACKEND_PID=""
  fi
}

cleanup() {
  stop_backend
  if [[ -n "$DRIVER_PID" ]]; then
    kill "$DRIVER_PID" 2>/dev/null || true
    wait "$DRIVER_PID" 2>/dev/null || true
  fi
  if [[ -z "${KEEP_DB:-}" ]]; then
    rm -f "$DB" "$DB-journal" "$DB-wal" "$DB-shm"
  fi
}
trap cleanup EXIT

wait_for() {  # url seconds
  for _ in $(seq 1 "$(( $2 * 5 ))"); do
    curl -sf -o /dev/null "$1" && return 0
    sleep 0.2
  done
  return 1
}

# Wipes and reseeds test.db, then (re)starts the API on it.
fresh_backend() {
  stop_backend
  (cd "$BACKEND" && "$PYTHON" scripts/seed_sqlite.py --db "$DB")
  if curl -s -o /dev/null "$API_URL/healthz"; then
    fail "port $API_PORT is already in use; stop that server or set API_PORT"
  fi
  (
    cd "$BACKEND"
    set -a; . tests/support/test.env; set +a
    export DATABASE_URL="sqlite:///$DB"
    export CORS_ORIGINS="http://127.0.0.1:$WEB_PORT"
    exec "$PYTHON" -m uvicorn tests.support.server:app --host 127.0.0.1 --port "$API_PORT"
  ) >>"$LOGS/backend.log" 2>&1 &
  BACKEND_PID=$!
  wait_for "$API_URL/healthz" 30 || fail "backend did not start (see $LOGS/backend.log)"
}

want() { [[ -n "$ONLY" ]] && [[ "$1" == "$ONLY" ]] || { [[ -z "$ONLY" ]] && (( $1 >= FROM )); }; }

step1() {
  log "Step 1: database setup and backend sanity"
  fresh_backend
  curl -sf "$API_URL/healthz" | grep -q '"ok"' || fail "GET /healthz"
  total="$(curl -sf "$API_URL/video/feed?limit=50" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["total"])')"
  expected="$(cd "$BACKEND" && "$PYTHON" -c 'from tests.support.seed_data import FEED; print(len(FEED))')"
  [[ "$total" == "$expected" ]] || fail "feed total $total, expected $expected seeded videos"
  echo "healthz ok; feed reads $total seeded videos from $DB"
  (cd "$BACKEND" && API_BASE_URL="$API_URL" "$PYTHON" -m pytest tests/sanity -q -p no:cacheprovider) \
    || fail "backend sanity tests"
  stop_backend
}

step2() {
  log "Step 2: frontend sanity (pub get, analyze, unit/widget tests, web build)"
  (
    cd "$FRONTEND"
    "$FLUTTER" pub get
    "$FLUTTER" analyze
    "$FLUTTER" test
    "$FLUTTER" build web --debug --no-web-resources-cdn --dart-define=API_BASE_URL="$API_URL"
  ) || fail "frontend sanity"
}

step3() {
  log "Step 3: API integration tests against the live backend"
  fresh_backend
  (cd "$BACKEND" && API_BASE_URL="$API_URL" "$PYTHON" -m pytest tests/integration -v -p no:cacheprovider) \
    || fail "backend integration tests"
  stop_backend
}

step4() {
  log "Step 4: E2E, Flutter web in headless Chrome"
  local chrome="${CHROME_EXECUTABLE:-$(command -v google-chrome || command -v chromium || true)}"
  [[ -x "$chrome" ]] || fail "no Chrome found; set CHROME_EXECUTABLE"
  command -v "$CHROMEDRIVER" >/dev/null || fail "chromedriver not found; set CHROMEDRIVER"
  local chrome_major driver_major
  chrome_major="$("$chrome" --version | grep -oE '[0-9]+' | head -1)"
  driver_major="$("$CHROMEDRIVER" --version | grep -oE '[0-9]+' | head -1)"
  [[ "$chrome_major" == "$driver_major" ]] \
    || fail "Chrome $chrome_major needs chromedriver $chrome_major (found $driver_major)"

  fresh_backend
  "$CHROMEDRIVER" --port="$DRIVER_PORT" >"$LOGS/chromedriver.log" 2>&1 &
  DRIVER_PID=$!
  wait_for "http://127.0.0.1:$DRIVER_PORT/status" 15 || fail "chromedriver did not start"

  (
    cd "$FRONTEND"
    # --no-web-resources-cdn: serve CanvasKit from the app instead of
    # www.gstatic.com, so the run needs no internet. The tall window builds
    # every seeded card without drag-scrolling.
    CHROME_EXECUTABLE="$chrome" "$FLUTTER" drive \
      -d web-server --headless --no-web-resources-cdn \
      --browser-dimension=420x3000 \
      --web-hostname=127.0.0.1 --web-port="$WEB_PORT" \
      --browser-name=chrome --chrome-binary="$chrome" --driver-port="$DRIVER_PORT" \
      --driver=test_driver/integration_test.dart \
      --target=integration_test/seeded_flow_test.dart \
      --dart-define=API_BASE_URL="$API_URL"
  ) 2>&1 | tee "$LOGS/e2e.log"
  [[ "${PIPESTATUS[0]}" == 0 ]] || fail "E2E"
  grep -q "All tests passed" "$LOGS/e2e.log" || fail "E2E did not report a pass"
  stop_backend
}

for n in 1 2 3 4; do
  if want "$n"; then "step$n"; fi
done

log "Pipeline passed (logs: $LOGS)"
