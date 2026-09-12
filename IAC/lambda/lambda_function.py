"""SQS -> ECS Fargate dispatcher Lambda.

Triggered by SQS event-source mapping on the ingest queue. For every S3
ObjectCreated record it invokes ecs:RunTask with container overrides carrying
the S3 coordinates and the derived VIDEO_ID. Failed records use partial-batch
response so SQS retries only what failed.

Duplicate dispatches are safe: the transcoder itself grabs a Redis lock
keyed on VIDEO_ID before doing any work.
"""

import json
import os
import pathlib
import urllib.parse
import boto3
from concurrent.futures import ThreadPoolExecutor, as_completed

ecs = boto3.client("ecs")

CLUSTER          = os.environ["ECS_CLUSTER"]
TASK_DEFINITION  = os.environ["ECS_TASK_DEFINITION"]
CONTAINER_NAME   = os.environ["CONTAINER_NAME"]
SUBNETS          = [s for s in os.environ["SUBNETS"].split(",") if s]
SECURITY_GROUPS  = [s for s in os.environ["SECURITY_GROUPS"].split(",") if s]
ASSIGN_PUBLIC_IP = os.environ.get("ASSIGN_PUBLIC_IP", "ENABLED")
PROCESSED_BUCKET = os.environ["PROCESSED_BUCKET"]
COMPLETION_URL   = os.environ["COMPLETION_QUEUE_URL"]
REDIS_HOST       = os.environ["REDIS_HOST"]
REDIS_PORT       = os.environ.get("REDIS_PORT", "6379")


def _derive_video_id(key: str) -> str:
    return pathlib.Path(key).stem


def _run_task(bucket: str, key: str) -> str:
    video_id = _derive_video_id(key)
    resp = ecs.run_task(
        cluster=CLUSTER,
        launchType="FARGATE",
        taskDefinition=TASK_DEFINITION,
        count=1,
        overrides={
            "containerOverrides": [{
                "name": CONTAINER_NAME,
                "environment": [
                    {"name": "S3_BUCKET",            "value": bucket},
                    {"name": "S3_KEY",               "value": key},
                    {"name": "VIDEO_ID",             "value": video_id},
                    {"name": "PROCESSED_BUCKET",     "value": PROCESSED_BUCKET},
                    {"name": "COMPLETION_QUEUE_URL", "value": COMPLETION_URL},
                    {"name": "REDIS_HOST",           "value": REDIS_HOST},
                    {"name": "REDIS_PORT",           "value": REDIS_PORT},
                ],
            }],
        },
        networkConfiguration={
            "awsvpcConfiguration": {
                "subnets":        SUBNETS,
                "securityGroups": SECURITY_GROUPS,
                "assignPublicIp": ASSIGN_PUBLIC_IP,
            }
        },
    )
    failures = resp.get("failures", [])
    if failures:
        raise RuntimeError(f"RunTask failures: {failures}")
    return resp["tasks"][0]["taskArn"]


def _handle_record(record: dict) -> tuple[str, bool]:
    message_id = record["messageId"]
    try:
        body = json.loads(record["body"])

        if body.get("Event") == "s3:TestEvent":
            print(f"[{message_id}] S3 TestEvent — skip")
            return message_id, True

        s3_records = body.get("Records", [])
        if not s3_records:
            print(f"[{message_id}] no Records — skip")
            return message_id, True

        for s3_rec in s3_records:
            bucket = s3_rec["s3"]["bucket"]["name"]
            key    = urllib.parse.unquote_plus(s3_rec["s3"]["object"]["key"])
            if not key.lower().endswith(".mp4"):
                print(f"[{message_id}] key {key} not .mp4 — skip")
                continue
            task_arn = _run_task(bucket, key)
            print(f"[{message_id}] dispatched video_id={_derive_video_id(key)} -> {task_arn}")
        return message_id, True
    except Exception as exc:
        print(f"[{message_id}] FAILED: {exc}")
        return message_id, False


def lambda_handler(event, context):
    records = event.get("Records", [])
    print(f"batch size={len(records)}")

    failed_ids = []
    with ThreadPoolExecutor(max_workers=min(10, max(1, len(records)))) as pool:
        futures = [pool.submit(_handle_record, r) for r in records]
        for fut in as_completed(futures):
            mid, ok = fut.result()
            if not ok:
                failed_ids.append({"itemIdentifier": mid})

    return {"batchItemFailures": failed_ids}
