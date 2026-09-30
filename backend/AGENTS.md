# AGENTS.md — backend (FastAPI on ECS Fargate)

FastAPI gateway for the video platform. Two ECS services built from a single
image:

1. **`api`** — HTTP API (uvicorn, 2 workers). ECS Express Mode service behind
   the internet-facing HTTPS ALB that Express Mode creates.
2. **`poller`** — plain Fargate service. Drains the transcoder's completion
   SQS queue and applies each status change to the `videos` row in
   PostgreSQL.

Users and videos live in RDS PostgreSQL (SQLAlchemy 2 + psycopg 3, schema
managed by Alembic). The API contract and schema come from
`../docs/api-and-db-schema-spec.md`.

Lives at the repo root, a sibling of `../IAC/` (Terraform + dispatcher
Lambda + Fargate transcoder). It owns the infrastructure it runs *on*
(`terraform/` here: ECS cluster and services, RDS PostgreSQL, IAM, SGs, ECR,
thumbnails bucket + CloudFront, log group)
and nothing in the pipeline — those coordinates arrive via
`terraform_remote_state`. Deployed on its own cadence: the pipeline stack is
applied first, then this one.

## Layout

```
backend/
├── app/
│   ├── main.py                 FastAPI app + CORS + router mount + /healthz
│   ├── config.py               pydantic-settings; env first, then .env
│   ├── clients.py              lazy singletons: cognito, s3, sqs, redis
│   ├── db.py                   engine + sessions; password from DB_PASSWORD or the RDS secret
│   ├── models.py               users + videos + transcode_results ORM models, enums
│   ├── users.py                upsert_user, shared by signup and get_current_user
│   ├── cache.py                video:meta:<id> Redis hash cache for GET /video/{id}
│   ├── crypto.py               HMAC-SHA256 secret_hash for Cognito app clients
│   ├── deps.py                 get_identity / get_optional_identity / get_current_user
│   ├── errors.py               APIError: HTTPException carrying a stable `code`
│   ├── schemas.py              pydantic request/response models
│   ├── routers/
│   │   ├── auth.py             /auth/{signup,verify-otp,resend-otp,forgot-password,
│   │   │                         reset-password,login,refresh,logout,me}
│   │   ├── upload.py           /upload/video/{url, url/thumbnail, save}
│   │   └── video.py            /video/{feed, mine, {id}, {id}/progress, {id}/view}
│   └── workers/
│       └── completion_poller.py  SQS -> PostgreSQL drainer (its own container)
├── migrations/                 Alembic env.py + versions/ (schema source of truth)
├── alembic.ini
├── terraform/                  ECS stack; see terraform/AGENTS.md
├── scripts/
│   ├── generate-env.sh         terraform state -> .env (local dev only)
│   └── push-image.sh           buildx (linux/amd64) -> ECR
├── Dockerfile                  one image, both processes
├── docker-compose.yml          api + poller + local postgres/redis, local parity only
├── requirements.txt
├── .env.example
├── deployment-guide.md
└── README.md
```

## Routes

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/auth/signup` | – | Cognito `sign_up` + insert `users` (Cognito user deleted if the insert fails) |
| POST | `/auth/verify-otp` | – | Cognito `confirm_sign_up` |
| POST | `/auth/resend-otp` | – | Cognito `resend_confirmation_code` |
| POST | `/auth/forgot-password` | – | Cognito `forgot_password`; same answer whether or not the account exists |
| POST | `/auth/reset-password` | – | Cognito `confirm_forgot_password` (code + new password) |
| POST | `/auth/login` | – | Cognito `initiate_auth`, sets HTTPOnly cookies |
| POST | `/auth/refresh` | refresh cookie | Cognito `get_tokens_from_refresh_token`, resets the access cookie |
| POST | `/auth/logout` | – | Cognito `revoke_token` on the refresh cookie if sent, clears cookies |
| GET  | `/auth/me` | cookie | Cognito `GetUser` + `users` row (created if missing) |
| GET  | `/upload/video/url` | cookie | Presigned PUT for raw MP4 (key `videos/<sub>/<uuid>.mp4`) |
| GET  | `/upload/video/url/thumbnail` | cookie | Presigned PUT for thumbnail JPEG (key `thumbnails/<sub>/<uuid>`) |
| POST | `/upload/video/save` | cookie | Insert `videos` row (status=PENDING); 409 if the key is already saved |
| GET  | `/video/feed` | – | PUBLIC + COMPLETED, paginated (`page`, `limit` ≤ 50), newest first |
| GET  | `/video/mine` | cookie | Caller's videos, any status, paginated |
| GET  | `/video/{video_id}` | optional | `video:meta` cache, else PostgreSQL; 404 unless viewable |
| PATCH | `/video/{video_id}` | cookie, owner | Edit title / description / visibility; drops the `video:meta` key |
| DELETE | `/video/{video_id}` | cookie, owner | Delete the row (204), drop the `video:meta` key, then remove the S3 objects in the background |
| GET  | `/video/{video_id}/progress` | optional | Redis `GET video:progress:<stem of s3_key>` + row status |
| POST | `/video/{video_id}/view` | optional | Atomic `views_count + 1` (204); 409 `video_not_ready` unless COMPLETED |
| GET  | `/healthz` | – | Liveness |

"Optional" auth: a COMPLETED video that is PUBLIC or UNLISTED is readable by
anyone; a PRIVATE or unfinished one only by its owner (everyone else gets
404). The caller is resolved only when ownership decides the answer. PATCH
and DELETE answer 404 to anyone but the owner, for the same reason.

Every error body is `{"detail": ..., "code": ...}`. `code` is a stable
snake_case string clients branch on (`user_not_confirmed`, `code_expired`,
`video_not_found`, ...); `detail` is for people and may change. Raise
`app.errors.APIError(status, code, detail)` rather than a bare
`HTTPException`; `main.py` fills in `not_found` / `method_not_allowed` /
`error` for anything that isn't one. Validation errors are 400 with code
`validation_error` and FastAPI's error list as `detail` (`main.py` remaps
the 422); a database `OperationalError` is 503 `database_unavailable`.

## Config

All config is env-driven via `pydantic_settings.BaseSettings`.

- **ECS:** task environment comes from `local.api_environment` /
  `local.poller_environment` in `terraform/ecs.tf`, built from both stacks'
  state. There is no `.env` in production.
- **Local:** `scripts/generate-env.sh` writes `.env` from the same Terraform
  states. Policy knobs (CORS, cookies, TTLs) are carried over from the
  previous file / environment / `.env.example`.

Settings default to empty, and each entrypoint calls `Settings.require(...)`
for the ones it needs: `main.py` for Cognito, the raw / thumbnails /
processed buckets, Redis, `CLOUDFRONT_DOMAIN`, and `THUMBNAILS_CDN_DOMAIN`;
the poller for
`COMPLETION_QUEUE_URL`. Both call `Settings.require_database()` (host, name,
user, and `DB_PASSWORD` or `DB_SECRET_ARN`). A missing value fails at
startup, not on first request.

Sensitive: `COGNITO_CLIENT_SECRET` and the database password. In ECS the
Cognito secret is injected from the pipeline's SSM SecureString
(`/<project>/cognito/client-secret`) via the container `secret` block, and
only the API execution role can read it. The database password is never in
the environment: `app/db.py` fetches the RDS-managed secret named by
`DB_SECRET_ARN` when it opens a connection, and refetches it once if
PostgreSQL rejects the password (rotation). `DB_PASSWORD` is for local runs
only. The local `.env` is gitignored, written mode 600, and excluded by
`.dockerignore`. Never COPY it into the image.

## Data ownership

- **Cognito** owns identity + password + OTP. Backend never stores
  passwords.
- **Schema** — owned by the Alembic revisions in `migrations/versions/`.
  `app/models.py` must match the latest revision (`alembic check` fails if
  they drift). Timestamps are `timestamptz`.
- **PostgreSQL `users`** — profile mirror keyed by `cognito_sub` (unique),
  with a UUID `id` that `videos.user_id` references (`ON DELETE CASCADE`).
  Written on `/auth/signup`, and by `get_current_user` if an authenticated
  Cognito user has no row.
- **PostgreSQL `videos`** — metadata + processing status. `s3_key` (unique)
  is the raw upload key; its filename stem is the transcoder's `VIDEO_ID`.
  Status is written in two places only:
  - `POST /upload/video/save` inserts the row with `status=PENDING`.
  - `completion_poller` applies `PROCESSING`, `COMPLETED` (+
    `dash_manifest_s3_key`, `hls_manifest_s3_key`, `duration_seconds`) and
    `FAILED` with guarded UPDATEs.

  The owner may edit title, description, and visibility (`PATCH`) and delete
  the row (`DELETE`); `POST /video/{id}/view` increments `views_count`
  without touching `updated_at`.
- **PostgreSQL `transcode_results`** — owned by the poller. Terminal results
  whose `videos` row did not exist yet, keyed by `raw_key`. See "Poller
  worker". Nothing in the API reads or writes it.
- **URLs are derived, not stored.** Responses build `manifest_url` (DASH)
  and `hls_url` from `CLOUDFRONT_DOMAIN` + `dash_manifest_s3_key` /
  `hls_manifest_s3_key`, and `thumbnail_url` from `THUMBNAILS_CDN_DOMAIN` +
  `thumbnail_s3_key`, at read time. `hls_url` is null for videos transcoded
  before HLS output existed.
- **Redis `video:progress:<stem>`** — read-only for the backend.
  Transcoder is the sole writer. Never mint progress values in the
  backend.
- **Redis `video:meta:<video_id>`** — owned by the API. A hash of the
  detail response, written on a `GET /video/{id}` miss with a TTL, only for
  videos anyone may watch. `PATCH` and `DELETE` delete the key after their
  commit (`cache.drop_video`); any new path that changes a video's detail
  must do the same. `views_count` is not invalidated, so a cached detail can
  lag the count by up to the TTL. Every Redis error is logged and falls back
  to PostgreSQL.

## Auth flow (mirror of `../IAC/deployment-guide.md` and `../docs/auth-implementation-guide.md`)

- App client MUST have a **client secret** and `USER_PASSWORD_AUTH`
  enabled — otherwise `initiate_auth` rejects the `SECRET_HASH`.
- HTTPOnly cookies are set on login. `Secure`/`SameSite` come from
  `COOKIE_SECURE` / `COOKIE_SAMESITE`: the `cookie_secure` /
  `cookie_samesite` tfvars in ECS, `.env` locally.
- `get_current_user` prefers the `access_token` cookie, falls back to
  `Authorization: Bearer <token>` for mobile clients that can't hold
  cookies. Both paths validate via Cognito `GetUser`.

## Poller worker

- Long-poll `receive_message` (10s, up to 10 msgs).
- For each message, JSON-parse and run one guarded UPDATE on the `videos`
  row where `s3_key = raw_key`:

  | Message status | Guard | Also sets |
  |---|---|---|
  | `processing` | only if the row is `PENDING` | – |
  | `completed` | none | `dash_manifest_s3_key` (from `manifest_uri`), `hls_manifest_s3_key` (from `hls_manifest_uri`, kept if absent), `duration_seconds` |
  | `failed` | only if the row is not `COMPLETED` | – (the error is logged) |

  SQS delivers at least once and out of order; the guards make replays and
  late messages no-ops, so a status never moves backwards. Messages from a
  transcoder that predates HLS have no `hls_manifest_uri`; that is valid.

- **No row yet** (the client hasn't called `/upload/video/save`, or the
  video was deleted mid-transcode): a `processing` message is dropped. A
  `completed` / `failed` one is parked in `transcode_results` (upsert on
  `raw_key`; `COMPLETED` is never replaced by `FAILED`) and the message is
  deleted.
- **Reconcile** — at the top of every loop iteration, in its own session:
  each parked result whose row now exists goes through the same guarded
  UPDATE and is deleted; parked results older than `PARKED_RESULT_TTL`
  (7 days) are pruned. A failure here is logged and the loop carries on.
- Clients play `manifest_url` (DASH) or `hls_url`; the processed bucket is
  private and CloudFront reads it through OAC.
- On success → `delete_message`.
- On any exception (bad JSON, unknown status, database error) → **do NOT**
  delete; SQS redelivers after visibility timeout, DLQ catches poison
  messages after `max_receive_count` (3 in terraform default).
- SIGINT/SIGTERM handled cleanly; the task definition sets a 30s
  `stopTimeout` (compose: `stop_grace_period`) so an in-flight batch finishes
  instead of going invisible until the timeout lapses.

## IAM

Defined in `terraform/iam.tf`, not by hand. Each service has its own pair:

- **API execution role** — ECR pull, logs on `/video-backend`,
  `ssm:GetParameters` on the Cognito client-secret parameter.
- **API task role** — `secretsmanager:GetSecretValue` on the RDS master
  secret; `cognito-idp:{SignUp, ConfirmSignUp, ResendConfirmationCode,
  ForgotPassword, ConfirmForgotPassword, InitiateAuth,
  GetTokensFromRefreshToken, RevokeToken, GetUser}` on the user pool (IAM
  doesn't evaluate these public APIs; listed for documentation);
  `cognito-idp:AdminDeleteUser` to roll back a signup whose `users` insert
  failed; `s3:PutObject` on `raw-bucket/videos/*` and
  `thumbnails-bucket/thumbnails/*` (the presigned URLs' authority);
  `s3:DeleteObject` on those same prefixes and the whole processed bucket,
  plus `s3:ListBucket` on the processed bucket, for `DELETE /video/{id}`.
- **Poller execution role** — ECR pull and logs only.
- **Poller task role** — `secretsmanager:GetSecretValue` on the RDS master
  secret; `sqs:{ReceiveMessage, DeleteMessage, GetQueueAttributes}` on the
  completion queue.
- **Express infrastructure role** — `AmazonECSInfrastructureRoleforExpressGatewayServices`,
  used by ECS to manage the API's ALB, cert, SGs, and autoscaling.

The API server itself never uploads to S3; the presigned URL delegates
its permission to the client. Its only direct S3 writes are the deletes
behind `DELETE /video/{id}`. Don't widen these policies — add a scoped
statement to the one role that needs it.

## Network

- Both services run in the pipeline VPC's public subnets with public IPs
  (there is no NAT). `terraform/network.tf` adds the ingress rule that opens
  Redis 6379 to the API SG only; the pipeline stack is not edited for it.
  Do NOT expose Redis to the internet.
- RDS sits in the same subnets with `publicly_accessible = false`. Its SG
  admits 5432 only from the API and poller SGs. Don't make it public or
  open it by CIDR.
- Redis calls fail fast (1s timeouts, no retries, `clients.py`), because
  every Redis use in the API has a fallback and a slow Redis would otherwise
  stall requests.
- The poller SG allows no inbound traffic. The API SG allows only the
  container port from the VPC CIDR, which is how the Express Mode ALB reaches
  the tasks (Express Mode can't add rules to an SG it didn't create). Public
  traffic reaches the API only through the ALB. There is no shell access; use
  logs or ECS Exec if you enable it.
- uvicorn runs with `--proxy-headers --forwarded-allow-ips '*'` so the ALB's
  `X-Forwarded-Proto` drives `Secure` cookie issuance. That trusts forwarded
  headers unconditionally, which is fine only because nothing outside the VPC
  can reach the container port.

## Editing conventions

- Add a new endpoint → new function in the matching `routers/*.py`, add
  request/response models to `schemas.py`, register the router in
  `main.py` if it's a new file.
- Errors → `APIError(status, code, detail)` from `app/errors.py`. A `code`
  is part of the API contract (the Flutter client maps on it): add new ones
  freely, never rename or reuse one.
- Never inline `boto3.client(...)` — go through `clients.py` so tests
  and cold-start behavior stay consistent.
- Never write video status from HTTP handlers except the initial
  `POST /upload/video/save` — the poller owns every later transition.
- Schema change → new Alembic revision in `migrations/versions/` + the
  matching `app/models.py` edit. Never edit a revision that has shipped.
  The API applies migrations on start; keep revisions safe to run while the
  previous code is still serving.
- Database access goes through `get_db` (handlers) or `new_session()`
  (poller). Keep handlers sync; the pool is sized per worker.
- Never log the `access_token` / `refresh_token` values.
- Cookies use `HttpOnly=True`, `Secure` toggled by config. Don't
  weaken them for local convenience — set `COOKIE_SECURE=false` in the
  dev `.env` instead.
- A new setting means four edits: `config.py`, `.env.example`, the heredoc
  in `scripts/generate-env.sh`, and the environment map in
  `terraform/ecs.tf` for each process that reads it.
- New Python dependency → `requirements.txt` → rebuild and push the image.

## Local dev

```
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env    # point at dev cognito / dev sqs
docker compose up -d postgres redis     # PostgreSQL on 127.0.0.1:5432
alembic upgrade head
uvicorn app.main:app --reload
python -m app.workers.completion_poller   # in another terminal
```

The compose Redis publishes no port, so host-run processes use the
`REDIS_HOST` in `.env`; if that is unreachable, progress reads return 0 and
the metadata cache is skipped.

Container parity (the API container runs `alembic upgrade head` on start):

```
docker build -t video-backend:local .
docker compose up        # API on 127.0.0.1:8000
```

## Deploy

Full playbook in `deployment-guide.md`. High-level, pipeline already applied:

1. First time only: `cd terraform && terraform init -upgrade &&
   terraform apply -target=aws_ecr_repository.backend`, so there is a repo to
   push to before the services exist.
2. `scripts/push-image.sh <tag>` — buildx `linux/amd64` to ECR.
3. `cd terraform && terraform apply -var image_tag=<tag>` — RDS, cluster,
   both services, IAM, SGs, thumbnails bucket + CDN, log group. Waits for the
   API to be healthy; each API task migrates the schema before serving.
4. `aws logs tail /video-backend --follow`.

Redeploy = steps 2 and 3 with a new tag.
