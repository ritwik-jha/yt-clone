# ytp — YouTube-like Video Platform

An event-driven video upload, transcoding, and streaming backend on AWS.
Clients upload MP4s straight to S3 via presigned URLs; an SQS-triggered
Lambda dispatches a Fargate task that transcodes to a 3-rendition DASH
ladder; a completion queue drives DynamoDB status writes; per-video
progress is published to Redis and read back through the API.

There is no client application in this repository — it is backend and
infrastructure only.

---

## Repo layout

```
.
├── backend/                       FastAPI gateway + SQS completion poller
│   ├── app/                       routers, schemas, config, boto3/redis clients
│   ├── terraform/                 EC2, IAM, SG, ECR, SSM env param, thumbnails bucket
│   ├── scripts/                   generate-env / push-image / deploy
│   ├── Dockerfile, docker-compose.yml
│   ├── deployment-guide.md        Deploy walkthrough (run after the pipeline)
│   └── README.md / AGENTS.md
│
├── IAC/                           The transcoding pipeline
│   ├── terraform/                 VPC, S3 x2, SQS x2 + DLQs, ECR, ECS, IAM,
│   │                              Lambda, ElastiCache Redis, DynamoDB x2
│   ├── lambda/                    SQS -> ecs:RunTask dispatcher
│   ├── transcoder/                Fargate container (ffmpeg -> DASH)
│   ├── deployment-guide.md        Step-by-step deploy walkthrough
│   └── AGENTS.md
│
└── *.md                           Design guides (see "Design docs" below)
```

`backend/` is deliberately a sibling of `IAC/`, not a child: it is
application code with its own deploy cadence and its own Terraform state. It
owns the instance it runs on and nothing in the pipeline, reading the
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
                    +--(2) SET video:progress:<id> 5..100  --> ElastiCache Redis
                    +--(3) ffmpeg 3-rendition DASH        --> local /tmp
                    +--(4) upload manifest+segments        --> S3 processed bucket
                    +--(5) SendMessage completion payload  --> SQS completion queue
                                                                    |
                                                                    | long-poll
                                                                    v
                                                  backend poller container (EC2)
                                                                    |
                                                                    | UpdateItem (idempotent)
                                                                    v
                                                       DynamoDB video-status
                                                                    ^
Client --GET /videos/{id}/progress-------------------> FastAPI backend --GET video:progress:<id> --> Redis
                                                                    +-> GetItem --> DynamoDB
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
- **Backend never writes terminal video status directly.** `POST
  /upload/video/save` writes the initial `PROCESSING` row; every
  COMPLETED/FAILED write goes through the SQS poller. This keeps DynamoDB
  write pressure off the Fargate completion burst.
- **Backend never mints Redis progress values.** The transcoder is the sole
  writer; the backend is read-only against Redis.
- **Cognito is the identity source of truth.** The DynamoDB `users` table
  is a mirror keyed by `cognito_sub`, for joins only — no passwords.

---

## What is and isn't provisioned

| Resource | Provisioned by |
|---|---|
| VPC, subnets, IGW, workload + Redis security groups | `IAC/terraform/network.tf` |
| S3 raw + processed buckets | `IAC/terraform/storage.tf` |
| SQS ingest + completion queues, both with DLQs | `IAC/terraform/storage.tf` |
| ElastiCache Serverless Redis | `IAC/terraform/redis.tf` |
| DynamoDB `video-status` + `users` | `IAC/terraform/dynamodb.tf` |
| ECR repo, ECS cluster + task definition, CW log group | `IAC/terraform/{ecr,ecs}.tf` |
| Lambda dispatcher + event source mapping | `IAC/terraform/lambda.tf` |
| EC2 instance, instance profile, security group | `backend/terraform/ec2.tf`, `iam.tf`, `network.tf` |
| ECR repo for the backend image, `.env` SSM parameter, log group | `backend/terraform/{ecr,ssm,logs}.tf` |
| S3 thumbnails bucket | `backend/terraform/storage.tf` |
| Cognito user pool + app client | `IAC/terraform/cognito.tf` |
| **ALB / TLS certificate in front of the backend** | manual / separate module |

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
terraform init && terraform apply
cd .. && scripts/push-image.sh && scripts/generate-env.sh --push-ssm
```

The two containers (`api`, `poller`) run from one image on a single EC2
instance. `scripts/generate-env.sh` derives the whole `.env`, Cognito
included, from both stacks' Terraform state — nothing is supplied by hand.

Backend locally:

```bash
cd backend && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
cp .env.example .env && uvicorn app.main:app --reload
```

Defaults: region `ap-south-1`, ARM64 container image. Both are overridable
in `terraform.tfvars`.

---

## Design docs

The five Markdown guides at the repo root predate the implementation and
are kept as design rationale, not as a description of the current system.
Where they disagree with the code, **the code is authoritative**. Known
divergences:

| Guide | Says | Actually implemented as |
|---|---|---|
| `auth-implementation-guide.md` | PostgreSQL user store, SQLAlchemy models | DynamoDB `users` table, no ORM |
| `s3-upload-and-metadata-guide.md` | PostgreSQL video metadata | DynamoDB `video-status` table |
| `ecs-sqs-deployment-guide.md` | Long-running Python SQS consumer daemon dispatches tasks | Lambda event source mapping dispatches tasks |
| `ecs-task-definition-spec.md` | Hand-written `task-definition.json` | `aws_ecs_task_definition` in `IAC/terraform/ecs.tf` |
| several | Backend processes under systemd in a venv | Docker containers, provisioned by `backend/terraform` |
| several | Flutter client flows | no client in this repo |

`video-streaming-scaling-and-bottlenecks.md` is forward-looking analysis
of scaling limits; most of it is not built yet.

---

## Project state

Infrastructure and application code are written but not yet deployed, and
there are no tests or CI.
