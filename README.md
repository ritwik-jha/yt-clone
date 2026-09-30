# ytp — YouTube-like Video Platform

An event-driven video upload, transcoding, and streaming backend on AWS.
Clients upload MP4s straight to S3 via presigned URLs; an SQS-triggered
Lambda dispatches a Fargate task that transcodes to a 3-rendition DASH
ladder; a completion queue carries status back to the backend, which
keeps users and videos in RDS PostgreSQL; per-video progress is published
to Redis and read back through the API.

There is no client application in this repository — it is backend and
infrastructure only.

---

## Repo layout

```
.
├── backend/                       FastAPI gateway + SQS completion poller
│   ├── app/                       routers, schemas, models, config, boto3/redis clients
│   ├── migrations/                Alembic schema migrations (users, videos)
│   ├── terraform/                 ECS Express API + poller service, RDS PostgreSQL, IAM, SGs,
│   │                              ECR, thumbnails bucket + CloudFront
│   ├── scripts/                   generate-env (local) / push-image
│   ├── Dockerfile, docker-compose.yml
│   ├── deployment-guide.md        Deploy walkthrough (run after the pipeline)
│   └── README.md / AGENTS.md
│
├── IAC/                           The transcoding pipeline
│   ├── terraform/                 VPC, S3 x2, SQS x2 + DLQs, ECR, ECS, IAM,
│   │                              Lambda, ElastiCache Redis, Cognito,
│   │                              CloudFront (processed bucket)
│   ├── lambda/                    SQS -> ecs:RunTask dispatcher
│   ├── transcoder/                Fargate container (ffmpeg -> DASH)
│   ├── deployment-guide.md        Step-by-step deploy walkthrough
│   └── AGENTS.md
│
└── docs/                          Specs and design guides (see "Design docs" below)
```

`backend/` is deliberately a sibling of `IAC/`, not a child: it is
application code with its own deploy cadence and its own Terraform state. It
owns the ECS services it runs as and nothing in the pipeline, reading the
pipeline stack's outputs through `terraform_remote_state`. Apply `IAC/`
first, `backend/` second; destroy in reverse.

Every component directory carries an `AGENTS.md` with directory-scoped
conventions. Read the relevant one before editing.

---

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
                    +--(2) SendMessage status=processing   --> SQS completion queue
                    +--(3) SET video:progress:<id> 5..100  --> ElastiCache Redis
                    +--(4) ffprobe duration + ffmpeg DASH  --> local /tmp
                    +--(5) upload manifest+segments        --> S3 processed bucket
                    +--(6) SendMessage status=completed    --> SQS completion queue
                                                                    |
                                                                    | long-poll
                                                                    v
                                                  backend poller (ECS service)
                                                                    |
                                                                    | guarded UPDATE (idempotent)
                                                                    v
                                                  RDS PostgreSQL videos
                                                                    ^
Client --GET /video/{id}/progress--------------------> FastAPI backend --GET video:progress:<id> --> Redis
                                                                    +-> SELECT --> PostgreSQL

Client --GET manifest_url (dash player)--> CloudFront --OAC--> S3 processed bucket
```

Transcode output is a DASH ladder at 1080p / 720p / 480p plus a 128 kbps
stereo AAC track, 4-second segments.

---

## Key design invariants

- **Video GUID = filename stem of the S3 key.** The API mints
  `videos/<cognito_sub>/<uuid>.mp4`; the dispatcher and the transcoder each
  derive `VIDEO_ID` independently from that stem. Changing the key
  convention means changing both
  `IAC/lambda/lambda_function.py::_derive_video_id` and
  `IAC/transcoder/transcoder.py::VIDEO_ID`.
- **Duplicate dispatch is safe.** SQS is at-least-once, so `ecs:RunTask`
  may fire twice for one upload. The transcoder's `SET NX` lock makes the
  loser exit(0) without redoing work. Release is a compare-and-delete Lua
  script keyed on the ECS task ARN, so a worker can only free its own lock.
- **The API never writes processing status.** `POST /upload/video/save`
  inserts the `videos` row as `PENDING`; every later status change
  (`PROCESSING`, `COMPLETED`, `FAILED`) is applied by the SQS poller with a
  guarded UPDATE that never moves a status backwards. The pipeline never
  connects to the database.
- **Backend never mints Redis progress values.** The transcoder is the sole
  writer of `video:progress:*`; the backend only reads it. The API does own
  its `video:meta:*` cache of public video metadata in the same Redis.
- **Cognito is the identity source of truth.** The PostgreSQL `users` table
  is a profile mirror keyed by `cognito_sub` — no passwords.

---

## What is and isn't provisioned

| Resource | Provisioned by |
|---|---|
| VPC, subnets, IGW, workload + Redis security groups | `IAC/terraform/network.tf` |
| S3 raw + processed buckets | `IAC/terraform/storage.tf` |
| SQS ingest + completion queues, both with DLQs | `IAC/terraform/storage.tf` |
| ElastiCache Serverless Redis | `IAC/terraform/redis.tf` |
| ECR repo, ECS cluster + task definition, CW log group | `IAC/terraform/{ecr,ecs}.tf` |
| Lambda dispatcher + event source mapping | `IAC/terraform/lambda.tf` |
| CloudFront distribution + OAC for the processed bucket | `IAC/terraform/cloudfront.tf` |
| Backend ECS cluster, Express Mode API service (creates its HTTPS ALB), poller service | `backend/terraform/ecs.tf` |
| Per-service execution/task roles, Express infrastructure role, SGs | `backend/terraform/{iam,network}.tf` |
| ECR repo for the backend image, log group | `backend/terraform/{ecr,logs}.tf` |
| RDS PostgreSQL (`users`, `videos`) and its security group | `backend/terraform/{database,network}.tf` |
| S3 thumbnails bucket + its CloudFront distribution | `backend/terraform/{storage,cloudfront}.tf` |
| Cognito user pool + app client, client-secret SSM parameter | `IAC/terraform/cognito.tf` |
| **Custom domain for the API or CloudFront** | not provisioned (AWS-issued `*.on.aws` / `*.cloudfront.net`) |

The Cognito app client has a secret and `USER_PASSWORD_AUTH` enabled, or
`initiate_auth` would reject the computed `SECRET_HASH`. The pool uses email
as the username (`username_attributes = ["email"]`), matching how
`backend/app/routers/auth.py` signs up, confirms, and logs in.

---

## Getting started

Pipeline infrastructure:

```bash
cd IAC/terraform && cp terraform.tfvars.example terraform.tfvars
```

then follow `IAC/deployment-guide.md` (apply → build/push the transcoder
image → deploy the backend → smoke test). This stack also creates the
Cognito user pool + app client the backend authenticates against.

Backend, after the pipeline is up — see `backend/deployment-guide.md`:

```bash
cd backend/terraform && cp terraform.tfvars.example terraform.tfvars
terraform init -upgrade && terraform apply -target=aws_ecr_repository.backend
cd .. && scripts/push-image.sh <tag>
terraform -chdir=terraform apply -var image_tag=<tag>
```

The two services (`api`, `poller`) run from one image. Their environment is
built by `backend/terraform/ecs.tf` from both stacks' Terraform state, the
Cognito client secret is injected from SSM, and both read the database
password from the RDS-managed Secrets Manager secret. Nothing is supplied by
hand. The API applies Alembic migrations when it starts.

Backend locally:

```bash
cd backend && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
cp .env.example .env && docker compose up -d postgres
.venv/bin/alembic upgrade head && .venv/bin/uvicorn app.main:app --reload
```

Defaults: region `ap-south-1` (overridable in `terraform.tfvars`), ARM64
transcoder image, x86_64 backend image.

---

## Design docs

`docs/api-and-db-schema-spec.md` is the API and database schema spec the
backend implements. The other guides in `docs/` predate the implementation
and are kept as design rationale, not as a description of the current
system. Where they disagree with the code, **the code is authoritative**.
Known divergences:

| Guide | Says | Actually implemented as |
|---|---|---|
| `ecs-sqs-deployment-guide.md` | Long-running Python SQS consumer daemon dispatches tasks | Lambda event source mapping dispatches tasks |
| `ecs-task-definition-spec.md` | Hand-written `task-definition.json` | `aws_ecs_task_definition` in `IAC/terraform/ecs.tf` |
| several | Backend processes under systemd in a venv | ECS services (Express Mode API + Fargate poller), provisioned by `backend/terraform` |
| several | Flutter client flows | no client in this repo |

`video-streaming-scaling-and-bottlenecks.md` is forward-looking analysis
of scaling limits; most of it is not built yet.

---

## Project state

Infrastructure and application code are written but not yet deployed, and
there are no tests or CI.
