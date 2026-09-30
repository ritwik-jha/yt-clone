"""Completion queue poller.

Drains the SQS `completion_queue_url` populated by the transcoder Fargate
tasks and applies each status change to the matching `videos` row, matched on
s3_key = the message's raw_key. Runs as its own ECS service
(backend/terraform/ecs.tf).

Semantics:
  * Long-poll 10s, batch up to 10 messages.
  * SQS delivers at least once and out of order, so every UPDATE is guarded
    and never moves a row backwards: PROCESSING only replaces PENDING, FAILED
    never replaces COMPLETED, and a replayed message is a no-op.
  * A completed/failed message can beat the client's POST /upload/video/save.
    Its row does not exist yet, so the message stays on the queue, redelivers
    after the visibility timeout, and lands in the DLQ only if the row never
    appears. A processing message for a missing row is dropped; the terminal
    message that follows carries everything that matters.
  * On a database error the message is not deleted, so it redelivers.
  * The transcoder reports `manifest_uri` as s3://<bucket>/<key>. The row
    stores the key; the API builds the CloudFront URL when it reads it.
"""

import json
import logging
import signal
import sys
import time
from urllib.parse import urlparse

from sqlalchemy import func, select, update
from sqlalchemy.orm import Session

from app.clients import sqs
from app.config import get_settings
from app.db import new_session
from app.models import Video, VideoStatus

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


class RowNotSaved(Exception):
    """The upload's videos row does not exist yet; retry later."""


def _manifest_key(manifest_uri: str) -> str:
    parsed = urlparse(manifest_uri)
    key = parsed.path.lstrip("/")
    if parsed.scheme != "s3" or not key:
        raise ValueError(f"unexpected manifest_uri: {manifest_uri!r}")
    return key


def _apply(db: Session, msg: dict) -> None:
    raw_key = msg["raw_key"]
    status = VideoStatus(msg["status"].upper())
    stmt = (
        update(Video)
        .where(Video.s3_key == raw_key)
        .values(status=status, updated_at=func.now())
        .execution_options(synchronize_session=False)
    )

    if status == VideoStatus.PROCESSING:
        stmt = stmt.where(Video.status == VideoStatus.PENDING)
    elif status == VideoStatus.COMPLETED:
        duration = msg.get("duration_seconds")
        stmt = stmt.values(
            dash_manifest_s3_key=_manifest_key(msg["manifest_uri"]),
            duration_seconds=func.coalesce(
                int(duration) if duration is not None else None, Video.duration_seconds,
            ),
        )
    elif status == VideoStatus.FAILED:
        stmt = stmt.where(Video.status != VideoStatus.COMPLETED)
        log.info("transcode failed raw_key=%s error=%s", raw_key, msg.get("error", ""))
    else:
        raise ValueError(f"unexpected status: {msg['status']!r}")

    if db.execute(stmt).rowcount:
        db.commit()
        log.info("applied status=%s raw_key=%s", status.value, raw_key)
        return

    exists = db.scalar(select(Video.id).where(Video.s3_key == raw_key)) is not None
    db.rollback()
    if exists:
        log.info("ignored stale status=%s raw_key=%s", status.value, raw_key)
    elif status == VideoStatus.PROCESSING:
        log.info("no row yet for raw_key=%s; dropping processing message", raw_key)
    else:
        raise RowNotSaved(raw_key)


def _handle(message: dict) -> bool:
    try:
        body = json.loads(message["Body"])
        with new_session() as db:
            _apply(db, body)
        return True
    except RowNotSaved as exc:
        log.info("no row yet for raw_key=%s; leaving the message for redelivery", exc)
        return False
    except Exception as exc:
        log.exception("failed to process message: %s", exc)
        return False


def run() -> None:
    s = get_settings()
    s.require("completion_queue_url")
    s.require_database()
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
