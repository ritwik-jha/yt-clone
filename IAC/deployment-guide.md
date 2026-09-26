# Video Transcoding Pipeline — Deployment Guide

Serverless, event-driven video transcoding pipeline on AWS with per-video
Redis locking, progress tracking, and asynchronous SQS→DynamoDB status
persistence via a backend poller.

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
                                                                    │ send completion
                                                                    ▼
                                                     [ SQS completion queue ]
                                                                    │
                                                                    │ poll
                                                                    ▼
                                                      [ Backend app poller ]
                                                                    │
                                                                    │ PutItem / UpdateItem
                                                                    ▼
                                                       [ DynamoDB video-status ]
```

Key design points:

- **Redis lock**: `SET video:lock:<video_guid> <task_token> NX EX 1800`.
  Prevents two Fargate workers from processing the same video (e.g. SQS
  redelivery from an ingest-message that took long to ack). Same lock
  doubles as the progress key namespace.
- **Progress**: `SET video:progress:<video_guid> <percent>`. Written after
  each stage (5 → 25 → 80 → 95 → 100). Every progress write refreshes the
  lock TTL, so long transcodes cannot lose their lock mid-flight.
- **Completion via SQS, not HTTP**: transcoder pushes a JSON message onto
  the completion queue. Backend app polls it and does the DynamoDB write
  asynchronously — the transcoder never blocks on API latency.
- **DynamoDB PAY_PER_REQUEST**: serverless, no capacity planning; the
  backend uses it as the durable video-status store.

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
│   ├── dynamodb.tf             # video-status table (backend data store)
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
│   └── transcoder.py           # lock -> download -> ffmpeg -> upload -> completion SQS
└── deployment-guide.md         # (this file)

../backend/                     # FastAPI gateway + completion poller (EC2)
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
| DynamoDB table name | `dynamodb_table_name` | `video-status` | `terraform.tfvars` |
| DynamoDB partition key | hard-coded `video_id` (string) | — | `dynamodb.tf` if you rename |
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

- **The backend app and the EC2 instance it runs on.** Both live in a
  second Terraform stack at `../backend/terraform/`, applied after this
  one. It provisions the instance, its IAM role (scoped to the tables,
  buckets, and queue below), its security group, an ECR repo, the
  thumbnails bucket, and the SSM parameter carrying the backend `.env`.
  It reads this stack's outputs via `terraform_remote_state` and does not
  modify anything here — except for one ingress rule it adds to
  `aws_security_group.redis` so the instance can reach the cache.
  Walkthrough: `../backend/deployment-guide.md`.
- **The Cognito user pool + app client.** The `users` DynamoDB table is
  provisioned here (`dynamodb.tf`), but the identity provider it mirrors
  is not — provision it manually or in a separate module.
- **An ALB or TLS certificate** in front of the backend.

### 1.3 Backend poller — contract

Implemented by `../backend/app/workers/completion_poller.py`, run as the
`poller` container on the backend instance. It drains the completion queue
and upserts DynamoDB:

- **Queue URL / ARN**: `completion_queue_url` / `completion_queue_arn`
  (Terraform outputs).
- **Message body** (JSON):
  ```json
  {
    "video_id":     "8b2e-...-9f01",
    "raw_bucket":   "my-org-raw-videos",
    "raw_key":      "raw/8b2e-...-9f01.mp4",
    "status":       "completed" | "failed",
    "manifest_uri": "s3://my-org-processed-videos/8b2e-.../dash/manifest.mpd",
    "error":        "",
    "task_token":   "arn:aws:ecs:...:task/...",
    "timestamp":    1736467200
  }
  ```
- **Recommended DynamoDB write**:
  ```
  UpdateItem  table=video-status
              key    = { video_id: <video_id> }
              set    status, manifest_uri, error, updated_at = <timestamp>
  ```
- **Idempotency**: use `UpdateItem` (not `PutItem`) so redelivered
  messages just overwrite the same attributes.
- **Progress endpoint**: for the client-facing `GET /videos/{id}/progress`
  endpoint, the backend reads `video:progress:<video_id>` from Redis (same
  `redis_endpoint` output). No DynamoDB round-trip needed for progress.
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
`completion_queue_arn`, `redis_endpoint`, `dynamodb_table`.

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
cp terraform.tfvars.example terraform.tfvars   # cognito_user_pool_arn, thumbnails_bucket_name
terraform init && terraform apply              # EC2, IAM, SG, ECR, SSM, thumbnails bucket

cd ..
scripts/push-image.sh                          # build + push the backend image
scripts/generate-env.sh --push-ssm             # this stack's outputs -> .env -> SSM
```

That stack reads the outputs from Step 2 through `terraform_remote_state`,
so nothing is copied by hand. It also adds the one ingress rule that lets
the instance reach `redis_endpoint` on 6379.

### Step 5 — Smoke test

Filename stem becomes `VIDEO_ID`:

```bash
RAW_BUCKET=$(terraform -chdir=../terraform output -raw raw_bucket)
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

# DynamoDB row (after poller writes)
aws dynamodb get-item \
  --table-name "$(terraform -chdir=../terraform output -raw dynamodb_table)" \
  --key "{\"video_id\": {\"S\": \"$VIDEO_ID\"}}"

# Processed output
aws s3 ls "s3://$(terraform -chdir=../terraform output -raw processed_bucket)/$VIDEO_ID/dash/"
```

---

## 4. Updating

- **Infra**: edit `.tf` → `terraform apply`.
- **Transcoder**: rebuild + push image (Step 3). ECS pulls `:latest` on
  next `RunTask`.
- **Lambda**: edit `IAC/lambda/lambda_function.py` → `terraform apply`
  (source hash triggers redeploy).
- **Backend**: edit `backend/` → re-sync to the EC2 instance and
  `systemctl restart backend completion-poller`.

---

## 5. Teardown

Destroy the backend stack **first** — it holds an ingress rule on this
stack's Redis security group, and that rule blocks the SG's deletion:

```bash
cd backend/terraform && terraform destroy
cd ../../IAC/terraform && terraform destroy
```

S3 buckets have `force_destroy = true`. ECR is not force-deleted — run
`aws ecr batch-delete-image` first if it blocks `destroy`.

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
  VPC, and the backend stack places its instance in the same VPC. If you
  move the backend elsewhere, VPC-peer or add an NLB/PrivateLink. Don't
  expose Redis to the internet.
- **Duplicate dispatches are safe**: SQS at-least-once + Lambda partial-
  batch means occasional replays. The Redis lock in the transcoder
  suppresses duplicate work; a duplicate dispatch just exits cleanly.
- **DynamoDB write cadence**: the backend poller is the sole DynamoDB
  writer, decoupling burst write pressure from the transcoder fleet.
  With PAY_PER_REQUEST billing there's no capacity ceiling to breach on
  spikes.
- **ARM64 vs X86_64**: `cpu_architecture` must match the platform you
  `docker buildx --platform` for. Mismatch = task fails with `exec
  format error`.
