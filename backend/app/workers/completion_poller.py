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
  * A completed/failed message can beat the client's POST /upload/video/save,
    for instance when the app is killed between the upload and the save.
    Its row does not exist yet, so the result is parked in
    `transcode_results` and the message is deleted. Every loop iteration
    applies parked results whose row now exists, through the same guarded
    UPDATE, and prunes those older than PARKED_RESULT_TTL whose row never
    appeared. A processing message for a missing row is dropped; the terminal
    message that follows carries everything that matters.
  * On a database error the message is not deleted, so it redelivers.
  * The transcoder reports `manifest_uri` (DASH) and `hls_manifest_uri` as
    s3://<bucket>/<key>. The row stores the keys; the API builds the
    CloudFront URLs when it reads it. Messages from a transcoder that
    predates HLS have no `hls_manifest_uri`.
"""

import json
import logging
import signal
import sys
import time
from dataclasses import dataclass
from datetime import timedelta
from typing import Optional
from urllib.parse import urlparse

from sqlalchemy import delete, func, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.clients import sqs
from app.config import get_settings
from app.db import new_session
from app.models import TranscodeResult, Video, VideoStatus

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] completion-poller: %(message)s",
)
log = logging.getLogger(__name__)

# How long a parked result waits for its videos row. Past this the upload is
# treated as abandoned (or its video deleted mid-transcode).
PARKED_RESULT_TTL = timedelta(days=7)

_running = True


def _stop(*_):
    global _running
    log.info("shutdown signal received")
    _running = False


signal.signal(signal.SIGINT,  _stop)
signal.signal(signal.SIGTERM, _stop)


@dataclass(frozen=True)
class Result:
    raw_key: str
    status: VideoStatus
    dash_key: Optional[str] = None
    hls_key: Optional[str] = None
    duration_seconds: Optional[int] = None
    error: str = ""


def _manifest_key(manifest_uri: str) -> str:
    parsed = urlparse(manifest_uri)
    key = parsed.path.lstrip("/")
    if parsed.scheme != "s3" or not key:
        raise ValueError(f"unexpected manifest_uri: {manifest_uri!r}")
    return key


def _parse(msg: dict) -> Result:
    status = VideoStatus(msg["status"].upper())
    if status not in (VideoStatus.PROCESSING, VideoStatus.COMPLETED, VideoStatus.FAILED):
        raise ValueError(f"unexpected status: {msg['status']!r}")
    if status != VideoStatus.COMPLETED:
        return Result(raw_key=msg["raw_key"], status=status, error=msg.get("error") or "")
    duration = msg.get("duration_seconds")
    hls_uri = msg.get("hls_manifest_uri")
    return Result(
        raw_key=msg["raw_key"],
        status=status,
        dash_key=_manifest_key(msg["manifest_uri"]),
        hls_key=_manifest_key(hls_uri) if hls_uri else None,
        duration_seconds=int(duration) if duration is not None else None,
    )


def _update(db: Session, r: Result) -> bool:
    """The guarded UPDATE for one result. True if a row changed."""
    stmt = (
        update(Video)
        .where(Video.s3_key == r.raw_key)
        .values(status=r.status, updated_at=func.now())
        .execution_options(synchronize_session=False)
    )
    if r.status == VideoStatus.PROCESSING:
        stmt = stmt.where(Video.status == VideoStatus.PENDING)
    elif r.status == VideoStatus.COMPLETED:
        stmt = stmt.values(
            dash_manifest_s3_key=r.dash_key,
            hls_manifest_s3_key=func.coalesce(r.hls_key, Video.hls_manifest_s3_key),
            duration_seconds=func.coalesce(r.duration_seconds, Video.duration_seconds),
        )
    else:
        stmt = stmt.where(Video.status != VideoStatus.COMPLETED)
    return bool(db.execute(stmt).rowcount)


def _park(db: Session, r: Result) -> bool:
    """Upsert a terminal result for a row that is not saved yet. COMPLETED
    replaces anything; FAILED never replaces COMPLETED. False if the parked
    result was kept."""
    stmt = insert(TranscodeResult).values(
        raw_key=r.raw_key,
        status=r.status,
        dash_manifest_s3_key=r.dash_key,
        hls_manifest_s3_key=r.hls_key,
        duration_seconds=r.duration_seconds,
        error=r.error or None,
    )
    stmt = stmt.on_conflict_do_update(
        index_elements=[TranscodeResult.raw_key],
        set_={
            "status":               stmt.excluded.status,
            "dash_manifest_s3_key": stmt.excluded.dash_manifest_s3_key,
            "hls_manifest_s3_key":  stmt.excluded.hls_manifest_s3_key,
            "duration_seconds":     stmt.excluded.duration_seconds,
            "error":                stmt.excluded.error,
            "received_at":          func.now(),
        },
        where=(TranscodeResult.status != VideoStatus.COMPLETED)
        | (stmt.excluded.status == VideoStatus.COMPLETED),
    )
    # RETURNING yields no row when the WHERE above skips the update.
    return db.execute(stmt.returning(TranscodeResult.raw_key)).first() is not None


def _apply(db: Session, msg: dict) -> None:
    r = _parse(msg)
    if r.status == VideoStatus.FAILED:
        log.info("transcode failed raw_key=%s error=%s", r.raw_key, r.error)

    if _update(db, r):
        db.commit()
        log.info("applied status=%s raw_key=%s", r.status.value, r.raw_key)
        return

    exists = db.scalar(select(Video.id).where(Video.s3_key == r.raw_key)) is not None
    if exists:
        db.rollback()
        log.info("ignored stale status=%s raw_key=%s", r.status.value, r.raw_key)
    elif r.status == VideoStatus.PROCESSING:
        db.rollback()
        log.info("no row yet for raw_key=%s; dropping processing message", r.raw_key)
    elif _park(db, r):
        db.commit()
        log.info("no row yet for raw_key=%s; parked status=%s", r.raw_key, r.status.value)
    else:
        db.rollback()
        log.info("ignored stale status=%s raw_key=%s; a COMPLETED result is parked", r.status.value, r.raw_key)


def _reconcile(db: Session) -> None:
    """Apply parked results whose row has been saved since, then prune the
    ones that waited too long."""
    parked = db.scalars(
        select(TranscodeResult).join(Video, Video.s3_key == TranscodeResult.raw_key)
    ).all()
    for p in parked:
        r = Result(
            raw_key=p.raw_key,
            status=p.status,
            dash_key=p.dash_manifest_s3_key,
            hls_key=p.hls_manifest_s3_key,
            duration_seconds=p.duration_seconds,
            error=p.error or "",
        )
        applied = _update(db, r)
        db.execute(delete(TranscodeResult).where(TranscodeResult.raw_key == r.raw_key))
        db.commit()
        log.info(
            "%s parked status=%s raw_key=%s",
            "applied" if applied else "discarded stale", r.status.value, r.raw_key,
        )

    pruned = db.execute(
        delete(TranscodeResult)
        .where(TranscodeResult.received_at < func.now() - PARKED_RESULT_TTL)
    ).rowcount
    db.commit()
    if pruned:
        log.info("pruned %d parked results older than %d days", pruned, PARKED_RESULT_TTL.days)


def _handle(message: dict) -> bool:
    try:
        body = json.loads(message["Body"])
        with new_session() as db:
            _apply(db, body)
        return True
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
            with new_session() as db:
                _reconcile(db)
        except Exception as exc:
            log.exception("reconciling parked results failed: %s", exc)

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
