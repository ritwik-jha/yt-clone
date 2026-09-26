# AGENTS.md — IAC (video transcoding pipeline)

Serverless, event-driven video transcoding pipeline on AWS with per-video
Redis locking, progress tracking, and DynamoDB status persistence.

The application tier that fronts this pipeline (FastAPI gateway + SQS
completion poller) lives **outside this directory**, at `../backend/`.
See `../backend/AGENTS.md`.

## Component map

```
IAC/
├── terraform/     Provision ALL AWS infra (VPC, S3, SQS, ECR, ECS,
│                  IAM, Lambda, ElastiCache Redis, DynamoDB).
│                  Self-contained: creates its own VPC + subnets.
├── lambda/        SQS-triggered dispatcher. Reads S3 ObjectCreated
│                  events, invokes ecs:RunTask with per-message env
│                  overrides. Partial-batch failure reporting.
├── transcoder/    Fargate container. Redis lock -> download S3 ->
│                  ffmpeg DASH ladder -> upload S3 -> completion SQS.
│                  Writes progress % to Redis after each stage.
└── deployment-guide.md   Step-by-step deploy walkthrough.
```

Each of the three component directories has its own `AGENTS.md` with
directory-scoped conventions. The repo-root layout is in `../README.md`.

## Data flow (one video, happy path)

```
Client --presigned PUT--> S3 raw bucket
                             |
                             | s3:ObjectCreated
                             v
                        SQS ingest queue
                             |
                             | Lambda ESM (batch=10, window=5s)
                             v
                       Lambda dispatcher
                             |
                             | ecs:RunTask (overrides: S3_KEY, VIDEO_ID, ...)
                             v
                    Fargate transcoder container
                    +--(1) SET video:lock:<id> NX EX 1800  --> ElastiCache Redis
                    +--(2) SET video:progress:<id> 5..100  --> ElastiCache Redis
                    +--(3) ffmpeg 3-rendition DASH        --> local /tmp
                    +--(4) upload manifest+segments        --> S3 processed bucket
                    +--(5) SendMessage completion payload  --> SQS completion queue
                                                                    |
                                                                    | long-poll
                                                                    v
                                                  Backend completion_poller (EC2)
                                                                    |
                                                                    | UpdateItem (idempotent)
                                                                    v
                                                       DynamoDB video-status
                                                                    ^
Client --GET /videos/{id}/progress-------------------> FastAPI backend --GET video:progress:<id> --> Redis
                                                                    +-> GetItem --> DynamoDB
```

## Key design invariants

- **Video GUID = filename stem of S3 key.** The API mints
  `videos/<user_sub>/<uuid>.mp4`; the transcoder + lambda both derive
  `VIDEO_ID = pathlib.Path(key).stem`. If the naming convention changes,
  update both `lambda/lambda_function.py::_derive_video_id` and
  `transcoder/transcoder.py::VIDEO_ID`.
- **Redis lock ownership is per-task-token.** Release uses compare-and-
  delete Lua so a worker only frees its own lock. Every progress write
  refreshes the TTL — long transcodes never orphan themselves.
- **Duplicate dispatch is safe.** SQS at-least-once + Lambda ESM retries
  can cause repeat `ecs:RunTask` calls. The transcoder's `SET NX` lock
  causes duplicates to exit(0) without redoing work.
- **Backend never writes video status directly.** All writes to the
  `video-status` DDB table on completion happen via the SQS poller. This
  decouples DDB write throughput from the Fargate fleet's completion burst.
- **Backend never mints Redis progress values.** Progress is written by
  the transcoder only; the backend is read-only against Redis.
- **Cognito is the identity source of truth.** DDB `users` table is a
  mirror keyed by `cognito_sub` for FKs / joins only. The pool
  (`terraform/cognito.tf`) uses email as the username — `backend/app/routers/auth.py`
  signs up, confirms, and logs in with `Username=<email>` throughout.

## Ownership of resources

| Resource | Provisioned by | Consumed by |
|---|---|---|
| VPC + subnets + IGW + workload SG + redis SG | `terraform/network.tf` | Fargate, Redis |
| S3 raw + processed buckets | `terraform/storage.tf` | Client (presigned PUT), transcoder |
| S3 thumbnails bucket | `../backend/terraform/storage.tf` | Client (presigned PUT) |
| SQS ingest queue + DLQ | `terraform/storage.tf` | Lambda dispatcher |
| SQS completion queue + DLQ | `terraform/storage.tf` | Transcoder (send), backend poller (receive) |
| ElastiCache Serverless Redis | `terraform/redis.tf` | Transcoder (RW), backend (RO) |
| DynamoDB `video-status` + `users` | `terraform/dynamodb.tf` | Backend API, backend poller |
| ECR repo | `terraform/ecr.tf` | ECS |
| ECS cluster + task def + CW log group | `terraform/ecs.tf` | Lambda dispatcher |
| Lambda dispatcher + ESM | `terraform/lambda.tf` | SQS ingest queue |
| Cognito user pool + app client | `terraform/cognito.tf` | Backend |
| EC2 instance + instance profile + SG + ECR + SSM env param | `../backend/terraform/` | Backend + poller |
| ALB / TLS certificate | **manual / separate** | Backend |

Anything marked "manual / separate" is intentionally out of scope for both
stacks — noted in `deployment-guide.md` and `../backend/deployment-guide.md`.

The backend stack reads this one's outputs through `terraform_remote_state`
and never modifies resources listed as owned by `terraform/` here. Apply
order is this stack first; destroy order is the reverse, because the backend
stack holds an ingress rule on `aws_security_group.redis`.

## Cross-cutting env contract

The transcoder and dispatcher share this env surface (dispatcher injects
into container overrides at `ecs:RunTask` time):

```
S3_BUCKET               raw upload bucket
S3_KEY                  object key of the uploaded mp4
VIDEO_ID                filename stem, used as Redis key suffix + DDB PK
PROCESSED_BUCKET        destination bucket for DASH output
COMPLETION_QUEUE_URL    SQS queue that backend poller drains
REDIS_HOST / REDIS_PORT / REDIS_TLS
REDIS_LOCK_PREFIX       default: video:lock
REDIS_PROGRESS_PREFIX   default: video:progress
REDIS_LOCK_TTL_SECONDS  default: 1800
AWS_REGION
```

Keep these names identical across `terraform/ecs.tf` (task def env),
`terraform/lambda.tf` (dispatcher env), `lambda/lambda_function.py`
(overrides), and `transcoder/transcoder.py` (consumption).

## Editing conventions

- Terraform: HCL2, provider `hashicorp/aws ~> 5.60`. Do not accept
  `vpc_id`/`subnet_ids` as inputs — the module creates its own network.
- Python: 3.12, stdlib preferred. Third-party: `boto3`, `redis`, and
  (backend only) `fastapi` + `pydantic-settings`.
- Every environment-specific value is a variable / env — no hard-coded
  ARNs, account IDs, or bucket names in code.
- No emojis, no decorative logging, no defensive try/except that swallows
  errors without logging.

## Where to start

- Change infra shape → `terraform/` (then read that dir's `AGENTS.md`).
- Change transcode ladder or progress semantics → `transcoder/`.
- Add or change an API → `../backend/app/routers/` (outside this dir).
- Change how S3 events fan out to Fargate → `lambda/` +
  `terraform/lambda.tf`.

Full deploy walkthrough lives in `deployment-guide.md`.
