"""Fargate video transcoder entrypoint.

Flow per invocation:
  1. Derive VIDEO_ID from the S3 object key filename stem.
  2. Acquire a Redis lock  (SET video:lock:<id> <task_arn> NX EX <ttl>). Bail
     out if another worker already owns the lock — this deduplicates any
     accidental double-dispatches from SQS redelivery.
  3. Write progress to  video:progress:<id>  after each stage:
       download start ->  5
       download done  -> 25
       ffmpeg done    -> 80
       upload done    -> 95
       completed      -> 100 (also released)
     Every progress write refreshes the lock TTL so a long transcode does
     not lose its lock mid-way.
  4. ffmpeg writes one set of fMP4 segments with two manifests over them:
     DASH (manifest.mpd) and HLS (master.m3u8 + media_<n>.m3u8), for
     players without DASH support such as AVPlayer on iOS. The ladder
     scales to fit 1920x1080 / 1280x720 / 854x480 boxes, keeping the
     source's aspect ratio, so portrait video stays portrait.
  5. Status messages go to the completion SQS queue, which the backend
     poller drains into PostgreSQL: "processing" once the lock is held
     (best effort), then "completed" with both manifest URIs and the input's
     duration from ffprobe, or "failed" with the error, after which the task
     exits non-zero so ECS marks it failed.

Env contract (injected by dispatcher Lambda via containerOverrides):
  S3_BUCKET               raw upload bucket
  S3_KEY                  object key of the uploaded mp4
  PROCESSED_BUCKET        destination bucket for DASH/HLS output
  COMPLETION_QUEUE_URL    SQS queue backend poller drains
  REDIS_HOST / REDIS_PORT / REDIS_TLS
  REDIS_LOCK_PREFIX       default: video:lock
  REDIS_PROGRESS_PREFIX   default: video:progress
  REDIS_LOCK_TTL_SECONDS  default: 1800
  AWS_REGION              region for boto3 clients
"""

import json
import os
import pathlib
import subprocess
import sys
import time
import uuid

import boto3
import redis

RAW_BUCKET       = os.environ["S3_BUCKET"]
RAW_KEY          = os.environ["S3_KEY"]
PROCESSED_BUCKET = os.environ["PROCESSED_BUCKET"]
COMPLETION_URL   = os.environ["COMPLETION_QUEUE_URL"]
REGION           = os.environ.get("AWS_REGION", "ap-south-1")

REDIS_HOST      = os.environ["REDIS_HOST"]
REDIS_PORT      = int(os.environ.get("REDIS_PORT", "6379"))
REDIS_TLS       = os.environ.get("REDIS_TLS", "1") == "1"
LOCK_PREFIX     = os.environ.get("REDIS_LOCK_PREFIX", "video:lock")
PROGRESS_PREFIX = os.environ.get("REDIS_PROGRESS_PREFIX", "video:progress")
LOCK_TTL        = int(os.environ.get("REDIS_LOCK_TTL_SECONDS", "1800"))

# ECS task ARN — makes the lock value unique per worker so we only release
# a lock we still own.
TASK_TOKEN = os.environ.get("ECS_TASK_ARN") or uuid.uuid4().hex

# Video GUID = filename stem of the uploaded key.
# Assumption: uploads use key format `<...prefix.../><video_guid>.mp4`.
# Override by setting VIDEO_ID explicitly in containerOverrides.
VIDEO_ID = os.environ.get("VIDEO_ID") or pathlib.Path(RAW_KEY).stem

WORK_DIR   = pathlib.Path("/tmp/transcode") / VIDEO_ID
INPUT_FILE = WORK_DIR / "input.mp4"
OUTPUT_DIR = WORK_DIR / "dash"
MANIFEST   = OUTPUT_DIR / "manifest.mpd"
# Written by the dash muxer next to MANIFEST (-hls_playlist 1).
HLS_MASTER = "master.m3u8"

# Output ladder: (width, height) box, video bitrate, maxrate, bufsize.
# Each rung scales to fit its box, so a portrait source comes out as
# e.g. 608x1080 rather than stretched to 1920x1080.
LADDER = [
    (1920, 1080, "5000k", "5350k", "7500k"),
    (1280,  720, "2800k", "2996k", "4200k"),
    ( 854,  480, "1400k", "1498k", "2100k"),
]

LOCK_KEY     = f"{LOCK_PREFIX}:{VIDEO_ID}"
PROGRESS_KEY = f"{PROGRESS_PREFIX}:{VIDEO_ID}"

s3  = boto3.client("s3",  region_name=REGION)
sqs = boto3.client("sqs", region_name=REGION)

rds = redis.Redis(
    host=REDIS_HOST, port=REDIS_PORT,
    ssl=REDIS_TLS, ssl_cert_reqs=None,
    socket_timeout=5, socket_connect_timeout=5,
    decode_responses=True,
)


def log(msg: str) -> None:
    print(f"[transcoder {VIDEO_ID}] {msg}", flush=True)


def acquire_lock() -> bool:
    ok = rds.set(LOCK_KEY, TASK_TOKEN, nx=True, ex=LOCK_TTL)
    if ok:
        log(f"lock acquired ({LOCK_KEY} ttl={LOCK_TTL}s)")
        return True
    holder = rds.get(LOCK_KEY)
    log(f"lock already held by {holder} — exiting")
    return False


# Release only if we still own the lock (compare-and-delete via Lua).
_RELEASE_LUA = """
if redis.call('get', KEYS[1]) == ARGV[1] then
  return redis.call('del', KEYS[1])
else
  return 0
end
"""


def release_lock() -> None:
    try:
        rds.eval(_RELEASE_LUA, 1, LOCK_KEY, TASK_TOKEN)
    except Exception as exc:
        log(f"release_lock failed (ignored): {exc}")


def set_progress(pct: int) -> None:
    """Write progress + extend the lock TTL in a single pipeline."""
    try:
        pipe = rds.pipeline()
        pipe.set(PROGRESS_KEY, str(pct), ex=LOCK_TTL)
        pipe.expire(LOCK_KEY, LOCK_TTL)
        pipe.execute()
        log(f"progress={pct}%")
    except Exception as exc:
        log(f"set_progress({pct}) failed (non-fatal): {exc}")


def download_input() -> None:
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    set_progress(5)
    log(f"downloading s3://{RAW_BUCKET}/{RAW_KEY} -> {INPUT_FILE}")
    s3.download_file(RAW_BUCKET, RAW_KEY, str(INPUT_FILE))
    set_progress(25)


def probe_duration() -> int | None:
    """Whole seconds of input, or None if ffprobe cannot tell (non-fatal)."""
    cmd = [
        "ffprobe", "-v", "error", "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1", str(INPUT_FILE),
    ]
    try:
        out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
        seconds = round(float(out.strip()))
    except (OSError, subprocess.CalledProcessError, ValueError) as exc:
        log(f"probe_duration failed (non-fatal): {exc}")
        return None
    log(f"duration={seconds}s")
    return seconds


def run_ffmpeg() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    cmd = ["ffmpeg", "-y", "-i", str(INPUT_FILE)]
    cmd += ["-map", "0:v:0"] * len(LADDER) + ["-map", "0:a:0?"]
    cmd += [
        "-c:v", "libx264", "-preset", "veryfast", "-profile:v", "main",
        "-keyint_min", "48", "-g", "48", "-sc_threshold", "0",
    ]
    for i, (width, height, bitrate, maxrate, bufsize) in enumerate(LADDER):
        cmd += [
            f"-b:v:{i}", bitrate, f"-maxrate:{i}", maxrate, f"-bufsize:{i}", bufsize,
            # ffmpeg applies the source's rotation metadata before this
            # filter, so phone video recorded upright is scaled as portrait.
            f"-filter:v:{i}",
            f"scale=w={width}:h={height}:force_original_aspect_ratio=decrease:force_divisible_by=2",
        ]
    cmd += [
        "-c:a", "aac", "-b:a", "128k", "-ac", "2",
        "-f", "dash",
        "-seg_duration", "4",
        "-use_template", "1", "-use_timeline", "1",
        "-init_seg_name", "init-$RepresentationID$.m4s",
        "-media_seg_name", "chunk-$RepresentationID$-$Number%05d$.m4s",
        "-adaptation_sets", "id=0,streams=v id=1,streams=a",
        "-hls_playlist", "1", "-hls_master_name", HLS_MASTER,
        str(MANIFEST),
    ]
    log("running ffmpeg…")
    subprocess.run(cmd, check=True)
    set_progress(80)


def upload_output() -> tuple[str, str]:
    """Upload everything ffmpeg wrote; return the DASH and HLS manifest URIs."""
    if not (OUTPUT_DIR / HLS_MASTER).is_file():
        raise RuntimeError(f"ffmpeg did not write {HLS_MASTER}")
    base_prefix = f"{VIDEO_ID}/dash"
    log(f"uploading DASH/HLS -> s3://{PROCESSED_BUCKET}/{base_prefix}/")
    for path in OUTPUT_DIR.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(OUTPUT_DIR).as_posix()
        key = f"{base_prefix}/{rel}"
        content_type = (
            "application/dash+xml"               if rel.endswith(".mpd")
            else "application/vnd.apple.mpegurl" if rel.endswith(".m3u8")
            else "video/iso.segment"             if rel.endswith(".m4s")
            else "application/octet-stream"
        )
        s3.upload_file(
            str(path), PROCESSED_BUCKET, key,
            ExtraArgs={"ContentType": content_type},
        )
    set_progress(95)
    base_uri = f"s3://{PROCESSED_BUCKET}/{base_prefix}"
    return f"{base_uri}/{MANIFEST.name}", f"{base_uri}/{HLS_MASTER}"


def send_status(
    status: str, manifest_uri: str = "", hls_manifest_uri: str = "",
    error: str = "", duration_seconds: int | None = None,
) -> None:
    body = {
        "video_id":         VIDEO_ID,
        "raw_bucket":       RAW_BUCKET,
        "raw_key":          RAW_KEY,
        "status":           status,
        "manifest_uri":     manifest_uri,
        "hls_manifest_uri": hls_manifest_uri,
        "duration_seconds": duration_seconds,
        "error":            error,
        "task_token":       TASK_TOKEN,
        "timestamp":        int(time.time()),
    }
    sqs.send_message(
        QueueUrl=COMPLETION_URL,
        MessageBody=json.dumps(body),
        MessageAttributes={
            "video_id": {"DataType": "String", "StringValue": VIDEO_ID},
            "status":   {"DataType": "String", "StringValue": status},
        },
    )
    log(f"status message sent status={status}")


def main() -> int:
    if not acquire_lock():
        return 0  # duplicate dispatch — exit cleanly, do not fail the task

    try:
        # Best effort: the terminal message carries everything that matters,
        # so a lost "processing" message must not fail the transcode.
        try:
            send_status("processing")
        except Exception as exc:
            log(f"send_status(processing) failed (non-fatal): {exc}")
        download_input()
        duration = probe_duration()
        run_ffmpeg()
        manifest_uri, hls_manifest_uri = upload_output()
        send_status("completed", manifest_uri, hls_manifest_uri, duration_seconds=duration)
        set_progress(100)
        return 0
    except subprocess.CalledProcessError as exc:
        send_status("failed", error=f"ffmpeg exit {exc.returncode}")
        return exc.returncode
    except Exception as exc:
        send_status("failed", error=str(exc))
        log(f"FATAL: {exc}")
        return 1
    finally:
        release_lock()


if __name__ == "__main__":
    sys.exit(main())
