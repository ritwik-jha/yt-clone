# AGENTS.md — transcoder (Fargate container)

Ephemeral Fargate container: one Fargate task per video. Grabs a Redis
lock, reports "processing", downloads the raw MP4, probes its duration,
runs ffmpeg to produce a 3-rendition MPEG-DASH ladder, uploads to the
processed bucket, sends a completion message to SQS, and exits.

## Files

- `transcoder.py` — entrypoint. All lifecycle logic.
- `Dockerfile` — `python:3.12-slim-bookworm` + `apt install ffmpeg` (which
  also provides `ffprobe`) +
  `pip install -r requirements.txt` + `ENTRYPOINT python /app/transcoder.py`.
- `requirements.txt` — `boto3`, `redis`.
- `.dockerignore` — excludes `__pycache__`, `.venv`, `.git`, etc.

## Lifecycle (single invocation)

1. Derive `VIDEO_ID = pathlib.Path(S3_KEY).stem`.
2. **Acquire lock** — `SET video:lock:<VIDEO_ID> <task_token> NX EX 1800`.
   If it fails, another worker owns the video → exit `0` cleanly (do not
   fail the ECS task; SQS will not redrive).
3. **Report processing** — a `status=processing` message to
   `COMPLETION_QUEUE_URL`. Best effort: a send failure is logged and the
   transcode continues, because the terminal message carries everything the
   backend needs.
4. **Download** raw MP4 to `/tmp/transcode/<VIDEO_ID>/input.mp4`.
   Progress = 5 → 25.
5. **Probe duration** — `ffprobe` on the input, rounded to whole seconds.
   Non-fatal: `None` if ffprobe fails or reports no duration.
6. **ffmpeg** — 3-rendition x264 ladder (1080p / 720p / 480p) + AAC audio,
   DASH-muxed with 4s segments, template-based init/media naming.
   Progress = 80.
7. **Upload** every file under `/tmp/transcode/<VIDEO_ID>/dash/` to
   `s3://<PROCESSED_BUCKET>/<VIDEO_ID>/dash/*` with correct content-types
   (`application/dash+xml` for `.mpd`, `video/iso.segment` for `.m4s`).
   Progress = 95.
8. **Send completion message** (`status=completed`, with `manifest_uri`
   and `duration_seconds`) to `COMPLETION_QUEUE_URL`. Progress = 100. Any
   failure in steps 4–7 sends `status=failed` with `error` instead, and the
   task exits non-zero.
9. **Release lock** via compare-and-delete Lua (releases only if we still
   own it). Runs in `finally`.

## Redis semantics

- **Lock key**: `${REDIS_LOCK_PREFIX}:<VIDEO_ID>`, value = task token
  (ECS task ARN if set, else a uuid4 hex fallback), TTL =
  `REDIS_LOCK_TTL_SECONDS` (default 1800s).
- **Progress key**: `${REDIS_PROGRESS_PREFIX}:<VIDEO_ID>`, value = int
  percent as a string, TTL matches the lock TTL.
- Every `set_progress()` refreshes both keys' TTL via a pipeline — a
  long-running ffmpeg cannot orphan its lock as long as it emits at
  least one progress write before TTL expires.
- Release uses Lua `if get==token then del end` so a stale worker whose
  lock already expired cannot delete the new owner's lock.

## Status message schema

Sent to `COMPLETION_QUEUE_URL` via `sqs.send_message` (`send_status()`):

```json
{
  "video_id":         "<VIDEO_ID>",
  "raw_bucket":       "<S3_BUCKET>",
  "raw_key":          "<S3_KEY>",
  "status":           "processing" | "completed" | "failed",
  "manifest_uri":     "s3://<PROCESSED_BUCKET>/<VIDEO_ID>/dash/manifest.mpd",
  "duration_seconds": <int, or null>,
  "error":            "<empty unless failed>",
  "task_token":       "<lock owner token>",
  "timestamp":        <unix seconds>
}
```

`manifest_uri` and `duration_seconds` are set only on `completed`. The
backend poller matches the `videos` row on `raw_key` (the row's `s3_key`)
and never moves a status backwards, so duplicate or out-of-order messages
are harmless.

Message attributes: `video_id`, `status` (both String), for filtering and
debugging; the poller reads the JSON body.

## Env contract

Required (all injected by the dispatcher Lambda via `containerOverrides`):

```
S3_BUCKET  S3_KEY  VIDEO_ID  PROCESSED_BUCKET  COMPLETION_QUEUE_URL
REDIS_HOST  REDIS_PORT  REDIS_TLS
REDIS_LOCK_PREFIX  REDIS_PROGRESS_PREFIX  REDIS_LOCK_TTL_SECONDS
AWS_REGION
```

`VIDEO_ID` can also be inferred from `S3_KEY` if unset (filename stem
fallback in `transcoder.py`).

`ECS_TASK_ARN` is used as the lock token when present (Fargate exposes
it via task metadata; if unset, a per-invocation uuid4 is generated).

## IAM

Task role (`terraform/iam.tf::aws_iam_role.ecs_task`) needs:

- `s3:GetObject` on `raw_bucket/*`
- `s3:PutObject`, `s3:PutObjectAcl`, `s3:AbortMultipartUpload` on
  `processed_bucket/*`
- `s3:ListBucket` on both buckets
- `sqs:SendMessage` on the completion queue

No database, Secrets Manager, or Cognito permissions — those belong to the
backend.

## Building the image

```
AWS_REGION=$(terraform -chdir=../terraform output -raw aws_region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URL=$(terraform -chdir=../terraform output -raw ecr_repository_url)

aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

# arch MUST match terraform var.cpu_architecture (default ARM64)
docker buildx build --platform linux/arm64 -t "$ECR_URL:latest" --push .
```

Mismatch (e.g. amd64 image with `cpu_architecture=ARM64` task def) =
task fails on start with `exec format error`.

## Do / don't

- **Do** update progress after every long-running stage.
- **Do** exit `0` on lock collision. It is a normal dedup event, not a
  failure.
- **Don't** call the backend API directly (no HTTP callbacks — the
  completion path is SQS only).
- **Don't** connect to the backend's PostgreSQL. Status reaches it only
  through the completion queue.
- **Don't** widen the task role beyond the four permissions above.
