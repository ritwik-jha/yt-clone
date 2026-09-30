# AGENTS.md — lambda (SQS → ecs:RunTask dispatcher)

Single-file Python Lambda. Triggered by SQS event-source mapping on the
ingest queue. For every S3 ObjectCreated record it fires
`ecs:RunTask` with per-message container overrides, using a
ThreadPoolExecutor to parallelize dispatch inside one invocation.

## Files

- `lambda_function.py` — the whole thing. Handler:
  `lambda_function.lambda_handler`.

Bundled by `terraform/lambda.tf::data.archive_file.dispatcher` (source_dir
= this directory). Any file added here gets zipped in — keep the folder
minimal so cold-start stays small. No requirements.txt: `boto3` is
provided by the Lambda runtime.

## Contract

**Input**: SQS event batch (default `batch_size=10`,
`batch_window=5s`), each record's `body` = raw S3 event JSON or an
`s3:TestEvent` sent when the notification is first wired.

**Env** (populated by `terraform/lambda.tf`):

```
ECS_CLUSTER           target cluster
ECS_TASK_DEFINITION   task family (revision `:latest` implicit)
CONTAINER_NAME        must match container name inside the task def
SUBNETS               comma-separated subnet IDs (public, per module default)
SECURITY_GROUPS       comma-separated SG IDs
ASSIGN_PUBLIC_IP      ENABLED | DISABLED
PROCESSED_BUCKET      passed through as an env override to the container
COMPLETION_QUEUE_URL  passed through
REDIS_HOST / REDIS_PORT  passed through
```

**Output**: `{"batchItemFailures": [{"itemIdentifier": <messageId>}, ...]}`
— only failed records are redriven; the rest are deleted by the ESM.

## Behavior details

- `_derive_video_id(key) = pathlib.Path(key).stem`. Must stay in sync
  with `transcoder/transcoder.py::VIDEO_ID`.
- `s3:TestEvent` and non-`.mp4` keys are treated as **success** and
  removed from the queue.
- ECS overrides inject: `S3_BUCKET`, `S3_KEY`, `VIDEO_ID`,
  `PROCESSED_BUCKET`, `COMPLETION_QUEUE_URL`, `REDIS_HOST`, `REDIS_PORT`.
  The rest of the container env comes from the task def defaults.
- Any exception inside `_handle_record` marks that single record as
  failed — other records in the batch still succeed.
- ECS `resp['failures']` is treated as a hard error (raises), so
  RunTask throttles / capacity issues bounce the message back to SQS.

## Do / don't

- **Do** keep this file dependency-free. No `redis`, no HTTP libs. The
  dispatcher's sole job is `ecs:RunTask`.
- **Do** bump `terraform.tf.lambda_timeout_seconds` (and 6× ingest queue
  visibility) if you add work per record.
- **Don't** send status messages or touch the backend's database from here.
  Status writes belong to the backend poller; deduplication belongs to the
  transcoder's Redis lock.
- **Don't** hard-code cluster / task family. Everything comes from env.

## Local sanity check

```
python -c "import ast, sys; ast.parse(open('lambda_function.py').read())"
```

No test harness ships here; end-to-end is validated via the
`deployment-guide.md` §5 smoke test.
