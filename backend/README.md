# Video Platform Backend (FastAPI, ECS)

FastAPI service that fronts the video transcoding pipeline. Two ECS Fargate
services, built from the same image:

1. **`api`** — HTTP API (`uvicorn app.main:app`), an ECS Express Mode
   service behind an HTTPS ALB
2. **`poller`** — plain ECS service; drains the transcoder's SQS completion queue and
   applies each status change to PostgreSQL (`app.workers.completion_poller`)

Users and videos live in an RDS PostgreSQL instance that this stack owns. The
API contract and schema are specified in `../docs/api-and-db-schema-spec.md`.

This directory sits at the repo root, alongside `IAC/` — the Terraform,
dispatcher Lambda, and Fargate transcoder that make up the pipeline this
service fronts. It owns its own Terraform stack (`backend/terraform/`) for
the ECS services it runs as and their database, and consumes the pipeline
stack's outputs rather
than touching its resources. Deploy the pipeline first.

---

## API Surface

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/auth/signup` | – | Cognito `sign_up` + insert into `users` |
| POST | `/auth/verify-otp` | – | Cognito `confirm_sign_up` |
| POST | `/auth/resend-otp` | – | Send a new signup verification code |
| POST | `/auth/forgot-password` | – | Email a password reset code (same response whether or not the account exists) |
| POST | `/auth/reset-password` | – | Set a new password with the reset code |
| POST | `/auth/login` | – | Cognito `initiate_auth`, sets HTTPOnly cookies |
| POST | `/auth/refresh` | refresh cookie | New access cookie from the refresh token |
| POST | `/auth/logout` | – | Revokes the refresh token (if sent), clears cookies |
| GET  | `/auth/me` | cookie | Caller's `users` row |
| GET  | `/upload/video/url` | cookie | Presigned PUT for raw MP4 |
| GET  | `/upload/video/url/thumbnail` | cookie | Presigned PUT for thumbnail JPEG |
| POST | `/upload/video/save` | cookie | Insert the `videos` row (status=PENDING) |
| GET  | `/video/feed` | – | Paginated PUBLIC + COMPLETED videos, newest first |
| GET  | `/video/mine` | cookie | Paginated list of the caller's videos, any status |
| GET  | `/video/{video_id}` | optional | One video; cached in Redis `video:meta:<id>` |
| PATCH | `/video/{video_id}` | cookie, owner | Edit title, description, visibility |
| DELETE | `/video/{video_id}` | cookie, owner | Delete the video and, in the background, its S3 objects (204) |
| GET  | `/video/{video_id}/progress` | optional | Transcode percent from `video:progress:<stem>` |
| POST | `/video/{video_id}/view` | optional | Count one playback (204); 409 until COMPLETED |
| GET  | `/healthz` | – | Liveness |

Anyone may read a COMPLETED video that is PUBLIC or UNLISTED. A PRIVATE or
unfinished video is visible only to its owner; everyone else gets 404. Edit
and delete are owner-only and also answer 404 to everyone else.

Every error response has the shape `{"detail": ..., "code": ...}`. `code` is
a stable snake_case identifier for clients to branch on (for example
`user_not_confirmed`, `code_expired`, `too_many_attempts`, `video_not_found`,
`video_not_ready`); `detail` is human-readable and may change. Request
validation errors return 400 with code `validation_error` and a list of
field errors as `detail`; a database outage returns 503
`database_unavailable`.

Cookies set by login: `access_token` (1h, `Path=/`) and `refresh_token` (5d,
`Path=/auth/refresh`), `HttpOnly`, `Secure` (configurable), `SameSite=lax`.
Because of that path, browsers never send the refresh token to
`/auth/logout`, so logout revokes it only for clients that attach cookies
themselves. `get_current_user` also accepts `Authorization: Bearer <token>`.

---

## Layout

```
backend/
├── app/
│   ├── main.py                        # FastAPI app
│   ├── config.py                      # pydantic-settings: environment, then .env
│   ├── clients.py                     # boto3 + redis singletons
│   ├── db.py                          # SQLAlchemy engine + sessions, RDS secret lookup
│   ├── models.py                      # users, videos, transcode_results ORM models
│   ├── users.py                       # users-row upsert shared by signup and get_current_user
│   ├── cache.py                       # video:meta Redis cache
│   ├── crypto.py                      # Cognito HMAC secret_hash
│   ├── deps.py                        # get_current_user / optional identity dependencies
│   ├── errors.py                      # APIError with a stable error code
│   ├── schemas.py                     # request/response models
│   ├── routers/
│   │   ├── auth.py
│   │   ├── upload.py
│   │   └── video.py
│   └── workers/
│       └── completion_poller.py       # SQS -> PostgreSQL drainer
├── migrations/                        # Alembic env + revisions
├── alembic.ini
├── terraform/                         # ECS cluster + services, RDS, IAM, SGs, ECR, thumbnails bucket + CDN
├── scripts/
│   ├── generate-env.sh                # terraform state -> .env (local dev)
│   ├── push-image.sh                  # build + push the image to ECR
│   └── seed_sqlite.py                 # fresh SQLite test.db with the seed records
├── tests/
│   ├── sanity/                        # unit tests + in-process app on SQLite
│   ├── integration/                   # HTTP tests against a running test server
│   └── support/                       # seed data, fake Cognito/S3/Redis, test server
├── Dockerfile                         # one image, both processes
├── docker-compose.yml                 # api + poller + local postgres/redis
├── requirements.txt
├── requirements-dev.txt               # + pytest, httpx, fakeredis
├── .env.example
├── deployment-guide.md                # full deploy walkthrough
└── README.md
```

---

## Configuration

In ECS, each service's environment is built by `terraform/ecs.tf` from both
stacks' state, and `COGNITO_CLIENT_SECRET` is injected from the pipeline's
SSM SecureString. The database password is never in the environment: both
services get `DB_SECRET_ARN`, the RDS-managed Secrets Manager secret, and
read it when they open a connection (again after a rotation). No `.env`
exists in production.

For local runs, `.env.example` documents every variable and
`scripts/generate-env.sh` derives the infrastructure values the same way:

| Variable | Source |
|---|---|
| `AWS_REGION` | pipeline output `aws_region` |
| `S3_RAW_VIDEOS_BUCKET` | pipeline output `raw_bucket` |
| `S3_PROCESSED_BUCKET` | pipeline output `processed_bucket` (only `DELETE /video/{id}` uses it) |
| `COMPLETION_QUEUE_URL` | pipeline output `completion_queue_url` |
| `REDIS_HOST` / `REDIS_PORT` | pipeline outputs `redis_host` / `redis_port` |
| `REDIS_PROGRESS_PREFIX` | pipeline output `redis_progress_key_prefix` |
| `S3_THUMBNAILS_BUCKET` | backend output `thumbnails_bucket` |
| `CLOUDFRONT_DOMAIN` | pipeline output `cloudfront_domain_name` |
| `THUMBNAILS_CDN_DOMAIN` | backend output `thumbnails_cdn_domain` |
| `DB_*` | carried from `.env` / `.env.example` — local runs use the compose PostgreSQL, since RDS is private to the VPC |
| `COGNITO_USER_POOL_ID`, `COGNITO_CLIENT_ID`, `COGNITO_CLIENT_SECRET` | pipeline outputs `cognito_user_pool_id` / `cognito_user_pool_client_id` / `cognito_user_pool_client_secret` |
| everything else (CORS, cookies, TTLs, cache prefix) | carried from the existing `.env`, then the environment, then `.env.example` |

Cognito is provisioned by `IAC/terraform/cognito.tf` — a confidential app
client (secret + `USER_PASSWORD_AUTH`) against a pool that uses email as the
username, matching how `app/routers/auth.py` signs up and logs in.

The local `.env` is gitignored and written mode 600. It holds
`COGNITO_CLIENT_SECRET` — do not commit it, and do not bake it into the
image (`.dockerignore` excludes it).

---

## Deployment

Two ECS services in the `video-backend` cluster, both from the same image:

| Service | Kind | Command |
|---|---|---|
| `video-backend-api` | ECS Express Mode (HTTPS ALB, autoscaling) | `alembic upgrade head && uvicorn app.main:app --workers 2 --proxy-headers` |
| `video-backend-poller` | ECS service, Fargate, no load balancer | `python -m app.workers.completion_poller` |

`backend/terraform/` provisions the cluster, both services, the RDS
PostgreSQL instance, a separate execution and task role for each service,
the Express Mode infrastructure role, the SGs, the ECR repo, the thumbnails
bucket with its CloudFront distribution, and the CloudWatch log group. It
reads the pipeline stack's outputs via `terraform_remote_state` and never
modifies pipeline resources, apart from adding one ingress rule to the Redis
SG for the API.

The short version, assuming `IAC/terraform` is already applied:

```bash
cd backend/terraform
cp terraform.tfvars.example terraform.tfvars   # set thumbnails_bucket_name
terraform init -upgrade
terraform apply -target=aws_ecr_repository.backend   # first deploy only

cd ..
TAG="$(git rev-parse --short HEAD)"
scripts/push-image.sh "$TAG"
terraform -chdir=terraform apply -var image_tag="$TAG"
terraform -chdir=terraform output -raw api_url
```

Every API task runs `alembic upgrade head` before it serves traffic. The
migration takes a PostgreSQL advisory lock, so tasks starting together
apply it once.

Full walkthrough, including routine operations and teardown ordering:
**`deployment-guide.md`**.

Logs from both services go to the CloudWatch group `/video-backend`
(`aws logs tail /video-backend --follow`).

---

## Data Model (PostgreSQL)

The schema is defined by the Alembic revisions in `migrations/versions/`;
`app/models.py` mirrors it. Timestamps are `timestamptz`.

### `users`
- `id` UUID PK (`gen_random_uuid()`)
- `name` varchar(100), `email` varchar(255) unique, `cognito_sub`
  varchar(255) unique
- `created_at`, `updated_at`

### `videos`
- `id` UUID PK
- `title` varchar(150) (indexed), `description` text
- `s3_key` varchar(500) unique — the raw upload key; the poller matches
  transcoder messages on it, and its filename stem names the Redis progress
  key
- `thumbnail_s3_key` varchar(500); `dash_manifest_s3_key` and
  `hls_manifest_s3_key` varchar(500) (set by the poller on completion;
  `hls_manifest_s3_key` is null for videos transcoded before HLS output)
- `visibility` enum PUBLIC / PRIVATE / UNLISTED (indexed)
- `status` enum PENDING / PROCESSING / COMPLETED / FAILED (indexed)
- `user_id` FK to `users.id`, `ON DELETE CASCADE` (indexed)
- `views_count` bigint (incremented by `POST /video/{id}/view`),
  `duration_seconds` integer (from the transcoder's ffprobe)
- `created_at` (indexed), `updated_at`

Responses carry URLs, not keys: `manifest_url` (DASH) is
`https://<CLOUDFRONT_DOMAIN>/<dash_manifest_s3_key>`, `hls_url` is the same
for `hls_manifest_s3_key`, and `thumbnail_url` is
`https://<THUMBNAILS_CDN_DOMAIN>/<thumbnail_s3_key>`, all built at read time.

### `transcode_results`
Written and read only by the poller. Holds a transcoder's COMPLETED or
FAILED result when it arrives before the client has saved the `videos` row.
The poller applies it once the row exists, and prunes entries that are
still unmatched after 7 days.
- `raw_key` varchar(500) PK — the raw upload key (`videos.s3_key`)
- `status`, `dash_manifest_s3_key`, `hls_manifest_s3_key`,
  `duration_seconds`, `error`
- `received_at`

### Redis
- `video:progress:<stem>` — written by the transcoder, read by
  `GET /video/{video_id}/progress`. Never written by this backend.
- `video:meta:<video_id>` — hash cache for `GET /video/{video_id}`, written
  by the API with a TTL (`VIDEO_META_CACHE_TTL_SECONDS`). Only videos anyone
  may watch are cached. `PATCH` and `DELETE` remove the key; view counts are
  not invalidated, so a cached `views_count` can lag by up to the TTL. Every
  Redis failure falls back to PostgreSQL.

---

## Local development

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # point at dev cognito / dev sqs
docker compose up -d postgres redis
alembic upgrade head
uvicorn app.main:app --reload
```

The compose PostgreSQL listens on `127.0.0.1:5432` with the `DB_*` values
from `.env.example`. The compose Redis publishes no port, so a
host-run API reaches only the `REDIS_HOST` in `.env`; with that unreachable,
progress reads return 0 and the metadata cache is skipped.

Poller separately:
```bash
python -m app.workers.completion_poller
```

Or run both the way production does, against a locally built image. The
containers use the compose PostgreSQL and Redis, and the API container
applies migrations when it starts, as it does on ECS:

```bash
docker build -t video-backend:local .
docker compose up
```

Compose binds the API to `127.0.0.1:8000` unless `API_BIND` says otherwise,
and ships logs to CloudWatch — set `AWS_REGION` and have credentials
available, or comment out the `logging:` blocks for a purely local run.

## Testing

The tests need no AWS account and no PostgreSQL. They run the real app on a
SQLite file (`DATABASE_URL=sqlite:///./test.db`) with Cognito, S3 and Redis
replaced by in-process fakes (`tests/support/fakes.py`). The seed records live
in `tests/support/seed_data.py`: three users (password `Passw0rd!`, every
confirmation and reset code `123456`) and eight videos covering each
visibility and status.

The whole pipeline (backend sanity, frontend analyze/test/web build, API
integration tests, and the Flutter web E2E test in headless Chrome) is one
script at the repo root:

```bash
pip install -r backend/requirements-dev.txt
scripts/run_pipeline.sh              # or --from 3 / --only 4
```

It reseeds and restarts the server before each step that uses it, and removes
`test.db` and its processes when it exits. Step 4 needs Chrome and a
chromedriver of the same major version (`CHROME_EXECUTABLE`, `CHROMEDRIVER`).

By hand:

```bash
cd backend
python scripts/seed_sqlite.py                      # wipes and seeds ./test.db
set -a; . tests/support/test.env; set +a
uvicorn tests.support.server:app --port 8000 &     # the app on SQLite + fakes
python -m pytest tests/sanity                      # no server needed, except test_live_server
API_BASE_URL=http://127.0.0.1:8000 python -m pytest tests
```

The integration tests write to the database, so reseed and restart the server
before running them again. Restart it after reseeding in any case: the old
process keeps the deleted file open and fails with "readonly database".

SQLite stands in for PostgreSQL only in tests: the schema comes from the ORM
models (`Base.metadata.create_all`), not the Alembic revisions, and
`DATABASE_URL` must stay unset in deployed environments.

