# Video Transcoding Pipeline — Deployment Guide

Serverless, event-driven video transcoding pipeline on AWS with per-video
Redis locking, progress tracking, and asynchronous status reporting over
SQS to a backend poller, which persists it in the backend's PostgreSQL.

```
[ Client ]
    │ PUT
    ▼
[ S3 raw bucket ] --ObjectCreated--> [ SQS ingest queue ] --ESM--> [ Lambda dispatcher ]
                                                                             │
                                                                             │ ecs:RunTask
                                                                             ▼
                                              [ ECS Fargate: video-transcoder container ]
                                                        │           │
                              acquire lock + progress   │           │  download / ffmpeg / upload
                                                        ▼           ▼
                                             [ ElastiCache Redis ] [ S3 processed bucket ]
                                                                    │
                                                                    │ send status
                                                                    ▼
                                                     [ SQS completion queue ]
                                                                    │
                                                                    │ poll
                                                                    ▼
                                                      [ Backend app poller ]
                                                                    │
                                                                    │ guarded UPDATE
                                                                    ▼
                                             [ RDS PostgreSQL videos (backend stack) ]
```

Key design points:

- **Redis lock**: `SET video:lock:<video_guid> <task_token> NX EX 1800`.
  Prevents two Fargate workers from processing the same video (e.g. SQS
  redelivery from an ingest-message that took long to ack). Same lock
  doubles as the progress key namespace.
- **Progress**: `SET video:progress:<video_guid> <percent>`. Written after
  each stage (5 → 25 → 80 → 95 → 100). Every progress write refreshes the
  lock TTL, so long transcodes cannot lose their lock mid-flight.
- **Status via SQS, not HTTP**: the transcoder pushes JSON messages
  (`processing`, then `completed` or `failed`) onto the completion queue.
  The backend poller applies them to PostgreSQL asynchronously — the
  transcoder never blocks on API or database latency, and never holds
  database credentials.

---

## 0. Repo Layout

The pipeline infrastructure is this directory. The backend app that
consumes the completion queue lives at the repo root in `../backend/` and
is deployed separately (see `../backend/README.md`).

```
IAC/
├── terraform/
│   ├── providers.tf
│   ├── variables.tf
│   ├── network.tf              # VPC + public subnets + IGW + workload SG + redis SG
│   ├── storage.tf              # S3 raw/processed + SQS ingest+DLQ + SQS completion+DLQ + S3->SQS notif
│   ├── redis.tf                # ElastiCache Serverless Redis (locks + progress)
│   ├── cognito.tf              # User pool + app client + client-secret SSM parameter
│   ├── cloudfront.tf           # Playback CDN (OAC) for the processed bucket
│   ├── ecr.tf
│   ├── iam.tf                  # ECS exec/task roles + Lambda dispatcher role
│   ├── ecs.tf                  # Cluster + task definition
│   ├── lambda.tf               # Dispatcher fn + SQS ingest event source mapping
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── lambda/
│   └── lambda_function.py      # Ingest SQS -> ecs:RunTask
├── transcoder/
│   ├── Dockerfile              # python:3.12-slim + ffmpeg + redis client
│   ├── requirements.txt
│   └── transcoder.py           # lock -> processing SQS -> download -> ffprobe -> ffmpeg -> upload -> completion SQS
└── deployment-guide.md         # (this file)

../backend/                     # FastAPI gateway + completion poller (ECS) + RDS PostgreSQL
```

---

## 1. Assumptions

All defaults live in `terraform/variables.tf`; override any of these in
`terraform.tfvars` before applying.

| Assumption | Variable | Default | Where to change |
|---|---|---|---|
| AWS region | `aws_region` | `ap-south-1` | `terraform.tfvars` |
| Raw S3 bucket name (globally unique) | `raw_bucket_name` | — required | `terraform.tfvars` |
| Processed S3 bucket name (globally unique) | `processed_bucket_name` | — required | `terraform.tfvars` |
| Ingest SQS queue name | `sqs_queue_name` | `video-processing-queue` | `terraform.tfvars` |
| Completion SQS queue name | `completion_queue_name` | `video-completion-queue` | `terraform.tfvars` |
| ElastiCache Serverless cache name | `redis_cache_name` | `video-progress-cache` | `terraform.tfvars` |
| Redis lock key prefix | `redis_lock_key_prefix` | `video:lock` | `terraform.tfvars` |
| Redis progress key prefix | `redis_progress_key_prefix` | `video:progress` | `terraform.tfvars` |
| Redis lock TTL (seconds) | `redis_lock_ttl_seconds` | `1800` | `terraform.tfvars` |
| **VIDEO_ID derivation** | filename stem of the S3 key | — | See §2 below |
| VPC CIDR | `vpc_cidr` | `10.42.0.0/16` | `terraform.tfvars` |
| AZ / public subnet count | `az_count` | `2` | `terraform.tfvars` |
| Container CPU architecture | `cpu_architecture` | `ARM64` | Match your `docker buildx` platform |
| Fargate CPU / memory | `task_cpu` / `task_memory` | `1024` / `2048` | `terraform.tfvars` |
| Lambda batch size / window | `lambda_batch_size` / `lambda_batch_window_seconds` | `10` / `5` | `terraform.tfvars` |
| Ingest SQS visibility timeout | `sqs_visibility_timeout_seconds` | `180` | ≥ 6× lambda timeout |
| Max receives → DLQ | `sqs_max_receive_count` | `3` | `terraform.tfvars` |
| Cognito user pool name | `cognito_user_pool_name` | `video-transcoder-users` | `terraform.tfvars` |
| Cognito app client name | `cognito_client_name` | `video-backend-client` | `terraform.tfvars` |
| Cognito MFA | `cognito_mfa_configuration` | `OFF` | `terraform.tfvars` |

### 1.1 Assumptions the pipeline makes about the upload

- **Uploads are `.mp4`.** S3 notification filter and Lambda both check
  `.mp4` suffix.
- **The filename stem of the S3 key is the video GUID.** Example:
  `raw/8b2e-…-9f01.mp4` → `VIDEO_ID = 8b2e-…-9f01`. If your uploader uses
  a different convention:
  - Preferred: put the GUID in the S3 key filename.
  - Alternative: change `_derive_video_id()` in
    `lambda/lambda_function.py` to pull it from an S3 metadata header or a
    known key-path segment.

### 1.2 What this Terraform does NOT provision

- **The backend app and its ECS services.** They live in a second
  Terraform stack at `../backend/terraform/`, applied after this one. It
  provisions an ECS cluster, the API as an ECS Express Mode service (which
  creates its own HTTPS ALB and certificate), the poller as a Fargate
  service, the RDS PostgreSQL database holding users and videos, separate
  IAM roles per service (scoped to the buckets, queue, and secrets they
  use), their security groups, an ECR repo, and the thumbnails bucket with
  its CloudFront distribution. It reads this stack's outputs via
  `terraform_remote_state` and does not modify anything here, except for
  one ingress rule it adds to `aws_security_group.redis` so the API tasks
  can reach the cache. Walkthrough: `../backend/deployment-guide.md`.
- **Custom domains** for the API or the CloudFront distribution. Both use
  AWS-issued hostnames.

This stack **does** provision the CloudFront distribution (`cloudfront.tf`)
that serves DASH output from the private processed bucket through Origin
Access Control, and the SSM SecureString holding the Cognito client secret
that the backend API task reads at start.

The Cognito user pool + app client (`cognito.tf`) **is** provisioned here —
the pool uses email as the username (`username_attributes = ["email"]`),
matching how `../backend/app/routers/auth.py` signs up, confirms, and logs
in. The `users` table that mirrors it lives in the backend's PostgreSQL.

### 1.3 Backend poller — contract

Implemented by `../backend/app/workers/completion_poller.py`, run as the
poller ECS service. It drains the completion queue and updates the
backend's PostgreSQL `videos` table:

- **Queue URL / ARN**: `completion_queue_url` / `completion_queue_arn`
  (Terraform outputs).
- **Message body** (JSON):
  ```json
  {
    "video_id":     "8b2e-...-9f01",
    "raw_bucket":   "my-org-raw-videos",
    "raw_key":      "raw/8b2e-...-9f01.mp4",
    "status":           "processing" | "completed" | "failed",
    "manifest_uri":     "s3://my-org-processed-videos/8b2e-.../dash/manifest.mpd",
    "duration_seconds": 61,
    "error":            "",
    "task_token":       "arn:aws:ecs:...:task/...",
    "timestamp":        1736467200
  }
  ```
  `manifest_uri` and `duration_seconds` are set only on `completed`.
- **Write**: a guarded `UPDATE videos ... WHERE s3_key = <raw_key>`.
  `processing` only replaces `PENDING`; `failed` never replaces
  `COMPLETED`; `completed` stores `dash_manifest_s3_key` (the key parsed
  from `manifest_uri`) and `duration_seconds`. The API builds
  `https://<cloudfront_domain_name>/<dash_manifest_s3_key>` when it reads
  the row, and players load that.
- **Idempotency**: the guards make redelivered and out-of-order messages
  no-ops, so the poller never moves a status backwards.
- **Row not saved yet**: the row exists only after the client calls
  `POST /upload/video/save`. A `processing` message with no row is dropped;
  a `completed` or `failed` one is left on the queue to redeliver, and lands
  in the completion DLQ if the row never appears.
- **Progress endpoint**: `GET /video/{id}/progress` reads
  `video:progress:<video_id>` from Redis (same `redis_endpoint` output).
  No database round-trip beyond loading the video.
- **Failure handling**: on any exception the message is *not* deleted —
  SQS redelivers after the visibility timeout and the DLQ catches poison
  messages after `sqs_max_receive_count` receives.

---

## 2. Prerequisites

- Terraform ≥ 1.5, AWS CLI v2, Docker with `buildx`.
- AWS credentials in your shell (`aws sts get-caller-identity` works).
- Chosen S3 bucket names are globally unused.

---

## 3. Deployment Steps

### Step 1 — Configure variables

```bash
cd IAC/terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — at minimum raw/processed bucket names
```

### Step 2 — Provision infra

```bash
terraform init
terraform apply
```

Outputs to note: `ecr_repository_url`, `raw_bucket`, `completion_queue_url`,
`completion_queue_arn`, `redis_endpoint`, `cloudfront_domain_name`.

> The Lambda ships with a placeholder ECR image reference on the first
> apply. `ecs:RunTask` will fail until Step 3 pushes the image. Expected.

### Step 3 — Build & push the transcoder image

```bash
cd ../transcoder

AWS_REGION=$(terraform -chdir=../terraform output -raw aws_region 2>/dev/null || echo ap-south-1)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URL=$(terraform -chdir=../terraform output -raw ecr_repository_url)

aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

# Match cpu_architecture in tfvars. Use linux/amd64 if you set X86_64.
docker buildx build \
  --platform linux/arm64 \
  -t "$ECR_URL:latest" \
  --push .
```

### Step 4 — Deploy the backend + poller

A separate stack, applied after this one. Full walkthrough:
**`../backend/deployment-guide.md`**. In brief:

```bash
cd ../backend/terraform
cp terraform.tfvars.example terraform.tfvars   # thumbnails_bucket_name
terraform init -upgrade
terraform apply -target=aws_ecr_repository.backend   # repo first, so there is somewhere to push

cd ..
scripts/push-image.sh <tag>                    # build + push the backend image (linux/amd64)
terraform -chdir=terraform apply -var image_tag=<tag>   # RDS, cluster, API + poller services, IAM, SGs, thumbnails CDN
```

That stack reads the outputs from Step 2 through `terraform_remote_state`,
so nothing is copied by hand. It also adds the one ingress rule that lets
the API tasks reach `redis_endpoint` on 6379. The API applies its database
migrations when it starts.

### Step 5 — Smoke test

This exercises the pipeline alone. Filename stem becomes `VIDEO_ID`:

```bash
cd IAC   # if currently in backend/, use: cd ../IAC
RAW_BUCKET=$(terraform -chdir=terraform output -raw raw_bucket)
VIDEO_ID=$(uuidgen)
aws s3 cp ./sample.mp4 "s3://$RAW_BUCKET/raw/$VIDEO_ID.mp4"
```

Trace the pipeline:

```bash
# Dispatcher
aws logs tail /aws/lambda/video-transcoder-dispatcher --follow

# Fargate transcoder
aws logs tail /ecs/video-transcoder --follow

# Progress key (from any machine that can reach Redis)
redis-cli --tls -h <redis_endpoint host> -p 6379 GET video:progress:$VIDEO_ID

# Completion message on the queue (before your poller drains it)
aws sqs receive-message --queue-url "$(terraform -chdir=../terraform output -raw completion_queue_url)"

# Processed output
aws s3 ls "s3://$(terraform -chdir=../terraform output -raw processed_bucket)/$VIDEO_ID/dash/"
```

An upload made this way has no `videos` row, because only
`POST /upload/video/save` creates one. Once the backend poller is running
it drops the `processing` message and leaves the `completed` one to
redeliver until it reaches the completion DLQ. To see a row reach
`COMPLETED`, upload through the API instead
(`../backend/deployment-guide.md`).

---

## 4. Updating

- **Infra**: edit `.tf` → `terraform apply`.
- **Transcoder**: rebuild + push image (Step 3). ECS pulls `:latest` on
  next `RunTask`.
- **Lambda**: edit `IAC/lambda/lambda_function.py` → `terraform apply`
  (source hash triggers redeploy).
- **Backend**: edit `backend/` → `scripts/push-image.sh <tag>` →
  `terraform apply -var image_tag=<tag>` in `backend/terraform`.

---

## 5. Teardown

Destroy the backend stack **first** — it holds an ingress rule on this
stack's Redis security group, and that rule blocks the SG's deletion:

```bash
cd backend/terraform && terraform destroy
cd ../../IAC/terraform && terraform destroy
```

S3 buckets have `force_destroy = true`. ECR is not force-deleted — run
`aws ecr batch-delete-image` first if it blocks `destroy`. The backend's
RDS instance has deletion protection on by default, so its `destroy` fails
until you turn that off; `../backend/deployment-guide.md` covers the steps.

---

## 6. Gotchas

- **Container name alignment**: dispatcher Lambda's overrides target
  `CONTAINER_NAME` (`video-transcoder` by default). Keep
  `var.container_name` and the `name` inside `containerDefinitions`
  identical.
- **Visibility timeout ≥ 6× Lambda timeout**: AWS requires this for
  SQS-Lambda ESM. Defaults comply (180s vs 30s).
- **Lock TTL vs transcode duration**: for very long videos, raise
  `redis_lock_ttl_seconds`. TTL is refreshed on every progress write,
  but if two consecutive stages take longer than TTL the lock could
  expire. Default 1800s covers most content up to ~30 min per stage.
- **Redis reachability from the backend**: Redis lives in the pipeline
  VPC, and the backend stack places its ECS tasks in the same VPC. If you
  move the backend elsewhere, VPC-peer or add an NLB/PrivateLink. Don't
  expose Redis to the internet.
- **Duplicate dispatches are safe**: SQS at-least-once + Lambda partial-
  batch means occasional replays. The Redis lock in the transcoder
  suppresses duplicate work; a duplicate dispatch just exits cleanly.
- **Status write cadence**: the backend poller is the only writer of
  processing status, one message at a time, so a burst of completions
  from the transcoder fleet queues up in SQS instead of hitting the
  database at once.
- **ARM64 vs X86_64**: `cpu_architecture` must match the platform you
  `docker buildx --platform` for. Mismatch = task fails with `exec
  format error`.
