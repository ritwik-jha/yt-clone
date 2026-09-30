#!/usr/bin/env bash
#
# Generate backend/.env from Terraform state, for running the API and poller
# locally against the deployed AWS resources. The ECS services do not use
# this file — backend/terraform/ecs.tf builds their environment directly.
#
# Reads the outputs of the pipeline stack (IAC/terraform) and, when it has
# been applied, the backend stack (backend/terraform), and writes every
# infrastructure-derived variable into .env — including Cognito, which the
# pipeline stack provisions. Values no stack owns (cookie/CORS policy) are
# carried over from the existing .env, then from the process environment,
# then from .env.example. So are the DB_* settings: RDS is private to the VPC,
# so local runs use the PostgreSQL in docker-compose.yml, never the RDS
# endpoint.
#
# Two ways to read state:
#   default        `terraform -chdir=<dir> output -json`  (works with any backend)
#   --state FILE   parse a terraform.tfstate file directly (no terraform binary)
#
# Usage:
#   scripts/generate-env.sh
#   scripts/generate-env.sh --pipeline-dir ../IAC/terraform --out .env
#   scripts/generate-env.sh --state ../IAC/terraform/terraform.tfstate
#
# Requires: jq, and either terraform or --state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$BACKEND_ROOT/.." && pwd)"

PIPELINE_DIR="$REPO_ROOT/IAC/terraform"
BACKEND_TF_DIR="$BACKEND_ROOT/terraform"
PIPELINE_STATE=""
BACKEND_STATE=""
OUT_FILE="$BACKEND_ROOT/.env"
EXAMPLE_FILE="$BACKEND_ROOT/.env.example"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "  $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pipeline-dir)   PIPELINE_DIR="$2";   shift 2 ;;
    --backend-dir)    BACKEND_TF_DIR="$2"; shift 2 ;;
    --state)          PIPELINE_STATE="$2"; shift 2 ;;
    --backend-state)  BACKEND_STATE="$2";  shift 2 ;;
    --out)            OUT_FILE="$2";       shift 2 ;;
    -h|--help)        sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null || die "jq is required"

# ---------------------------------------------------------------- state read

# Both `terraform output -json` and the `.outputs` object of a state file use
# the same {"name": {"value": ..., "type": ...}} shape, so one reader covers
# local state, remote state, and a hand-supplied state file.
read_outputs() {  # $1 = terraform dir, $2 = optional state file
  local dir="$1" state="${2:-}"
  if [[ -n "$state" ]]; then
    [[ -f "$state" ]] || die "state file not found: $state"
    jq '.outputs // {}' "$state"
  else
    [[ -d "$dir" ]] || return 1
    command -v terraform >/dev/null || die "terraform not on PATH (use --state instead)"
    terraform -chdir="$dir" output -json 2>/dev/null || return 1
  fi
}

PIPELINE_OUT="$(read_outputs "$PIPELINE_DIR" "$PIPELINE_STATE")" \
  || die "could not read pipeline outputs from ${PIPELINE_STATE:-$PIPELINE_DIR} — has it been applied?"

[[ "$(jq 'length' <<<"$PIPELINE_OUT")" -gt 0 ]] \
  || die "pipeline state has no outputs — run 'terraform apply' in $PIPELINE_DIR first"

# The backend stack is optional here: on a first run it may not exist yet.
BACKEND_OUT="{}"
if BACKEND_OUT_TRY="$(read_outputs "$BACKEND_TF_DIR" "$BACKEND_STATE")"; then
  BACKEND_OUT="$BACKEND_OUT_TRY"
fi
[[ "$(jq 'length' <<<"$BACKEND_OUT")" -gt 0 ]] \
  || note "backend stack has no outputs yet — S3_THUMBNAILS_BUCKET and THUMBNAILS_CDN_DOMAIN will fall back"

pipeline_out() { jq -r --arg k "$1" '(.[$k].value // empty) | tostring' <<<"$PIPELINE_OUT"; }
backend_out()  { jq -r --arg k "$1" '(.[$k].value // empty) | tostring' <<<"$BACKEND_OUT"; }

# ------------------------------------------------------------ value fallback

# For keys Terraform does not own: current .env, then environment, then
# .env.example. Keys are [A-Z0-9_] so a literal sed match is safe.
from_file() {  # $1 = key, $2 = file
  [[ -f "$2" ]] || return 0
  sed -n "s/^${1}=//p" "$2" | tail -n 1
}

carried() {  # $1 = key
  local key="$1" val
  val="$(from_file "$key" "$OUT_FILE")"
  [[ -n "$val" ]] && { printf '%s' "$val"; return; }
  val="${!key:-}"
  [[ -n "$val" ]] && { printf '%s' "$val"; return; }
  from_file "$key" "$EXAMPLE_FILE"
}

require() {  # $1 = key, $2 = value
  [[ -n "$2" ]] || die "missing required value for $1"
  printf '%s' "$2"
}

# --------------------------------------------------------- resolve the values

AWS_REGION_V="$(require AWS_REGION "$(pipeline_out aws_region)")"
RAW_BUCKET="$(require S3_RAW_VIDEOS_BUCKET "$(pipeline_out raw_bucket)")"
COMPLETION_URL="$(require COMPLETION_QUEUE_URL "$(pipeline_out completion_queue_url)")"
REDIS_PREFIX="$(pipeline_out redis_progress_key_prefix)"

# redis_host/redis_port are discrete outputs; redis_endpoint ("host:port") is
# the older single output, kept as a fallback for pre-existing state files.
REDIS_HOST_V="$(pipeline_out redis_host)"
REDIS_PORT_V="$(pipeline_out redis_port)"
if [[ -z "$REDIS_HOST_V" ]]; then
  REDIS_ENDPOINT="$(require REDIS_HOST "$(pipeline_out redis_endpoint)")"
  REDIS_HOST_V="${REDIS_ENDPOINT%%:*}"
  REDIS_PORT_V="${REDIS_ENDPOINT##*:}"
fi
[[ -n "$REDIS_PORT_V" ]] || REDIS_PORT_V=6379

# Owned by the backend stack; falls back to whatever is already configured so
# that generating .env before the first backend apply still produces a usable
# file for local runs.
THUMB_BUCKET="$(backend_out thumbnails_bucket)"
if [[ -z "$THUMB_BUCKET" ]]; then
  THUMB_BUCKET="$(carried S3_THUMBNAILS_BUCKET)"
  # A fallback that landed on the .env.example value means nothing real was
  # configured; shipping that would presign uploads to a bucket nobody owns.
  if [[ "$THUMB_BUCKET" == "$(from_file S3_THUMBNAILS_BUCKET "$EXAMPLE_FILE")" ]]; then
    die "S3_THUMBNAILS_BUCKET is still the .env.example placeholder — apply backend/terraform or export a real bucket name"
  fi
  [[ -n "$THUMB_BUCKET" ]] || die "S3_THUMBNAILS_BUCKET unresolved — apply backend/terraform or set it in the environment"
fi

# Cognito is provisioned by the pipeline stack (IAC/terraform/cognito.tf),
# same as the other required values above — no manual carry-over needed.
COGNITO_POOL="$(require COGNITO_USER_POOL_ID "$(pipeline_out cognito_user_pool_id)")"
COGNITO_CLIENT="$(require COGNITO_CLIENT_ID "$(pipeline_out cognito_user_pool_client_id)")"
COGNITO_SECRET="$(require COGNITO_CLIENT_SECRET "$(pipeline_out cognito_user_pool_client_secret)")"
CLOUDFRONT="$(require CLOUDFRONT_DOMAIN "$(pipeline_out cloudfront_domain_name)")"

# The thumbnails distribution belongs to the backend stack. A placeholder only
# breaks thumbnail URLs rather than sending uploads anywhere, so warn and go on.
THUMB_CDN="$(backend_out thumbnails_cdn_domain)"
if [[ -z "$THUMB_CDN" ]]; then
  THUMB_CDN="$(carried THUMBNAILS_CDN_DOMAIN)"
  if [[ "$THUMB_CDN" == "$(from_file THUMBNAILS_CDN_DOMAIN "$EXAMPLE_FILE")" ]]; then
    note "THUMBNAILS_CDN_DOMAIN is the .env.example placeholder — thumbnail URLs will not resolve until backend/terraform is applied"
  fi
fi

# ------------------------------------------------------------------- emit

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

cat >"$TMP_FILE" <<EOF
# Generated by backend/scripts/generate-env.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Infrastructure values come from Terraform state; do not hand-edit those.
# Re-run the script after any 'terraform apply' that changes them.

# --- App ---
APP_HOST=$(carried APP_HOST)
APP_PORT=$(carried APP_PORT)
CORS_ORIGINS=$(carried CORS_ORIGINS)
ACCESS_COOKIE_MAX_AGE=$(carried ACCESS_COOKIE_MAX_AGE)
REFRESH_COOKIE_MAX_AGE=$(carried REFRESH_COOKIE_MAX_AGE)
COOKIE_SECURE=$(carried COOKIE_SECURE)
COOKIE_SAMESITE=$(carried COOKIE_SAMESITE)

# --- AWS ---
AWS_REGION=${AWS_REGION_V}

# --- Cognito (pipeline stack) ---
COGNITO_USER_POOL_ID=${COGNITO_POOL}
COGNITO_CLIENT_ID=${COGNITO_CLIENT}
COGNITO_CLIENT_SECRET=${COGNITO_SECRET}

# --- PostgreSQL (local; docker-compose.yml overrides DB_HOST/DB_SSLMODE) ---
DB_HOST=$(carried DB_HOST)
DB_PORT=$(carried DB_PORT)
DB_NAME=$(carried DB_NAME)
DB_USER=$(carried DB_USER)
DB_PASSWORD=$(carried DB_PASSWORD)
DB_SECRET_ARN=$(carried DB_SECRET_ARN)
DB_SSLMODE=$(carried DB_SSLMODE)
DB_POOL_SIZE=$(carried DB_POOL_SIZE)
DB_MAX_OVERFLOW=$(carried DB_MAX_OVERFLOW)

# --- S3 buckets ---
S3_RAW_VIDEOS_BUCKET=${RAW_BUCKET}
S3_THUMBNAILS_BUCKET=${THUMB_BUCKET}
PRESIGNED_URL_TTL_SECONDS=$(carried PRESIGNED_URL_TTL_SECONDS)

# --- SQS completion queue ---
COMPLETION_QUEUE_URL=${COMPLETION_URL}
COMPLETION_POLL_WAIT_SECONDS=$(carried COMPLETION_POLL_WAIT_SECONDS)
COMPLETION_MAX_MESSAGES=$(carried COMPLETION_MAX_MESSAGES)

# --- Redis (progress reads + video:meta cache) ---
REDIS_HOST=${REDIS_HOST_V}
REDIS_PORT=${REDIS_PORT_V}
REDIS_TLS=$(carried REDIS_TLS)
REDIS_PROGRESS_PREFIX=${REDIS_PREFIX:-$(carried REDIS_PROGRESS_PREFIX)}
REDIS_META_PREFIX=$(carried REDIS_META_PREFIX)
VIDEO_META_CACHE_TTL_SECONDS=$(carried VIDEO_META_CACHE_TTL_SECONDS)

# --- CloudFront (playback: processed bucket; thumbnails: backend stack) ---
CLOUDFRONT_DOMAIN=${CLOUDFRONT}
THUMBNAILS_CDN_DOMAIN=${THUMB_CDN}
EOF

mkdir -p "$(dirname "$OUT_FILE")"
install -m 600 "$TMP_FILE" "$OUT_FILE"
echo "wrote $OUT_FILE" >&2
