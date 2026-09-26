# Video Platform Backend (FastAPI, EC2)

FastAPI service that fronts the video transcoding pipeline. Two containers on
one EC2 instance, built from the same image and sharing one `.env`:

1. **`api`** — HTTP API (`uvicorn app.main:app`)
2. **`poller`** — drains the transcoder's SQS completion queue and writes
   DynamoDB (`app.workers.completion_poller`)

This directory sits at the repo root, alongside `IAC/` — the Terraform,
dispatcher Lambda, and Fargate transcoder that make up the pipeline this
service fronts. It owns its own Terraform stack (`backend/terraform/`) for
the instance it runs on, and consumes the pipeline stack's outputs rather
than touching its resources. Deploy the pipeline first.

---

## API Surface

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/auth/signup` | – | Cognito `sign_up` + mirror to `users` DDB table |
| POST | `/auth/verify-otp` | – | Cognito `confirm_sign_up` |
| POST | `/auth/login` | – | Cognito `initiate_auth`, sets HTTPOnly cookies |
| POST | `/auth/logout` | – | Clears cookies |
| GET  | `/auth/me` | cookie | Cognito `get_user` + DDB profile lookup |
| GET  | `/upload/video/url` | cookie | Presigned PUT for raw MP4 |
| GET  | `/upload/video/url/thumbnail` | cookie | Presigned PUT for thumbnail JPG |
| POST | `/upload/video/save` | cookie | Persist video row (status=PROCESSING) |
| GET  | `/videos/mine` | cookie | List caller's videos (GSI query) |
| GET  | `/videos/{video_id}` | – | Fetch one video row |
| GET  | `/videos/{video_id}/progress` | – | Read `video:progress:<id>` from Redis |
| GET  | `/healthz` | – | Liveness |

Cookies set by login: `access_token` (1h) and `refresh_token` (5d),
`HttpOnly`, `Secure` (configurable), `SameSite=lax`.

---

## Layout

```
backend/
├── app/
│   ├── main.py                        # FastAPI app
│   ├── config.py                      # pydantic-settings from .env
│   ├── clients.py                     # boto3 + redis singletons
│   ├── crypto.py                      # Cognito HMAC secret_hash
│   ├── deps.py                        # get_current_user dependency
│   ├── schemas.py                     # request/response models
│   ├── routers/
│   │   ├── auth.py
│   │   ├── upload.py
│   │   └── videos.py
│   └── workers/
│       └── completion_poller.py       # SQS -> DDB drainer
├── terraform/                         # EC2 + IAM + SG + ECR + SSM + thumbnails bucket
├── scripts/
│   ├── generate-env.sh                # terraform state -> .env (+ push to SSM)
│   ├── push-image.sh                  # build + push the image to ECR
│   └── deploy.sh                      # runs ON the instance: env -> pull -> up
├── systemd/
│   └── video-backend.service          # oneshot unit that runs deploy.sh
├── Dockerfile                         # one image, both processes
├── docker-compose.yml                 # api + poller services
├── requirements.txt
├── .env.example
├── deployment-guide.md                # full deploy walkthrough
└── README.md
```

---

## Configuration

`.env.example` documents every variable. In practice you do not fill it in by
hand — `scripts/generate-env.sh` derives the infrastructure values from the
Terraform state of both stacks:

| .env variable | Source |
|---|---|
| `AWS_REGION` | pipeline output `aws_region` |
| `DDB_VIDEOS_TABLE` | pipeline output `dynamodb_table` |
| `DDB_USERS_TABLE` | pipeline output `dynamodb_users_table` |
| `S3_RAW_VIDEOS_BUCKET` | pipeline output `raw_bucket` |
| `COMPLETION_QUEUE_URL` | pipeline output `completion_queue_url` |
| `REDIS_HOST` / `REDIS_PORT` | pipeline outputs `redis_host` / `redis_port` |
| `REDIS_PROGRESS_PREFIX` | pipeline output `redis_progress_key_prefix` |
| `S3_THUMBNAILS_BUCKET` | backend output `thumbnails_bucket` |
| `COGNITO_USER_POOL_ID`, `COGNITO_CLIENT_ID`, `COGNITO_CLIENT_SECRET` | **you** — not Terraform-managed |
| everything else (CORS, cookies, TTLs) | carried from the existing `.env`, then the environment, then `.env.example` |

Cognito is not created by any stack in this repo. Provision the user pool and
app client first; the app client MUST have a client secret and
`USER_PASSWORD_AUTH` enabled.

`.env` is gitignored and written mode 600. It holds
`COGNITO_CLIENT_SECRET` — do not commit it, and do not bake it into the
image (`.dockerignore` excludes it).

---

## Deployment

Two Docker containers on one EC2 instance, both from the same image:

| Container | Command |
|---|---|
| `video-backend-api` | `uvicorn app.main:app --workers 2 --proxy-headers` |
| `video-backend-poller` | `python -m app.workers.completion_poller` |

`backend/terraform/` provisions the instance, its IAM role, its security
group, the ECR repo, the thumbnails bucket, the CloudWatch log group, and an
SSM SecureString parameter that carries the `.env` to the box. It reads the
pipeline stack's outputs via `terraform_remote_state` and never modifies
pipeline resources.

The short version, assuming `IAC/terraform` is already applied:

```bash
cd backend/terraform
cp terraform.tfvars.example terraform.tfvars   # set cognito_user_pool_arn + thumbnails_bucket_name
terraform init && terraform apply

cd ..
scripts/push-image.sh
scripts/generate-env.sh --push-ssm             # needs COGNITO_* in the environment
aws ssm start-session --target "$(terraform -chdir=terraform output -raw instance_id)"
#   sudo systemctl restart video-backend
```

Full walkthrough, including exposing the API, routine operations, and
teardown ordering: **`deployment-guide.md`**.

Container logs go to the CloudWatch group `/video-backend`
(`aws logs tail /video-backend --follow`), not to journald.

---

## Data Model (DynamoDB)

### `users` table
- PK: `cognito_sub` (S)
- GSI `email-index` (PK: `email`)
- attrs: `name`, `email`, `created_at`

### `video-status` table
- PK: `video_id` (S)
- GSI `uploader-created-index` (PK: `uploader_sub`, SK: `created_at`)
- attrs written by API on save: `title`, `description`, `visibility`,
  `status=PROCESSING`, `video_key`, `thumbnail_key`, `uploader_sub`,
  `created_at`, `updated_at`
- attrs written by completion poller: `status` (COMPLETED/FAILED),
  `manifest_uri`, `error`, `updated_at`

### Redis
- `video:progress:<video_id>` — written by transcoder, read by
  `GET /videos/{video_id}/progress`. Not written by this backend.

---

## Local development

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # point at dev cognito / ddb / dev sqs
uvicorn app.main:app --reload
```

Poller separately:
```bash
python -m app.workers.completion_poller
```

Or run both the way production does, against a locally built image:

```bash
docker build -t video-backend:local .
docker compose up
```

Compose binds the API to `127.0.0.1:8000` unless `API_BIND` says otherwise,
and ships logs to CloudWatch — set `AWS_REGION` and have credentials
available, or comment out the `logging:` blocks for a purely local run.
