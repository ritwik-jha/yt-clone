"""Completion queue poller.

Drains the SQS `completion_queue_url` populated by the transcoder Fargate
tasks and asynchronously upserts DynamoDB `video-status` rows. Runs as its
own ECS service (backend/terraform/ecs.tf).

Semantics:
  * Long-poll 10s, batch up to 10 messages.
  * UpdateItem is idempotent — safe against SQS at-least-once delivery.
  * On DDB failure, do NOT delete the SQS message; it redelivers after the
    visibility timeout and eventually lands in the DLQ if it keeps failing.
  * The transcoder reports `manifest_uri` as s3://<bucket>/<key>. The row
    stores the key and the CloudFront playback URL built from it.
"""

import json
import logging
import signal
import sys
import time
from datetime import datetime, timezone
from urllib.parse import urlparse

from app.clients import sqs, videos_table
from app.config import get_settings

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] completion-poller: %(message)s",
)
log = logging.getLogger(__name__)

_running = True


def _stop(*_):
    global _running
    log.info("shutdown signal received")
    _running = False


signal.signal(signal.SIGINT,  _stop)
signal.signal(signal.SIGTERM, _stop)


def _manifest_fields(manifest_uri: str) -> tuple[str, str]:
    if not manifest_uri:
        return "", ""
    parsed = urlparse(manifest_uri)
    if parsed.scheme != "s3" or not parsed.path.lstrip("/"):
        raise ValueError(f"unexpected manifest_uri: {manifest_uri!r}")
    key = parsed.path.lstrip("/")
    return key, f"https://{get_settings().cloudfront_domain}/{key}"


def _upsert(msg: dict) -> None:
    video_id = msg["video_id"]
    now = datetime.now(timezone.utc).isoformat()
    manifest_key, manifest_url = _manifest_fields(msg.get("manifest_uri", ""))

    videos_table().update_item(
        Key={"video_id": video_id},
        UpdateExpression=(
            "SET #s = :s, manifest_key = :k, manifest_url = :m, #e = :e, updated_at = :u"
        ),
        ExpressionAttributeNames={"#s": "status", "#e": "error"},
        ExpressionAttributeValues={
            ":s": msg["status"].upper(),
            ":k": manifest_key,
            ":m": manifest_url,
            ":e": msg.get("error", ""),
            ":u": now,
        },
    )
    log.info("upserted video_id=%s status=%s", video_id, msg["status"])


def _handle(message: dict) -> bool:
    try:
        body = json.loads(message["Body"])
        _upsert(body)
        return True
    except Exception as exc:
        log.exception("failed to process message: %s", exc)
        return False


def run() -> None:
    s = get_settings()
    s.require("completion_queue_url", "cloudfront_domain")
    log.info("poller starting url=%s", s.completion_queue_url)

    while _running:
        try:
            resp = sqs().receive_message(
                QueueUrl=s.completion_queue_url,
                MaxNumberOfMessages=s.completion_max_messages,
                WaitTimeSeconds=s.completion_poll_wait_seconds,
                MessageAttributeNames=["All"],
            )
        except Exception as exc:
            log.exception("receive_message failed: %s", exc)
            time.sleep(5)
            continue

        for m in resp.get("Messages", []):
            if _handle(m):
                try:
                    sqs().delete_message(
                        QueueUrl=s.completion_queue_url,
                        ReceiptHandle=m["ReceiptHandle"],
                    )
                except Exception as exc:
                    log.exception("delete_message failed: %s", exc)

    log.info("poller exiting")


if __name__ == "__main__":
    try:
        run()
    except Exception as exc:
        log.exception("fatal: %s", exc)
        sys.exit(1)
