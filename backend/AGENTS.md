# AGENTS.md — backend (FastAPI, Dockerized on EC2)

FastAPI gateway for the video platform. Two containers on one EC2 instance,
built from a single image and sharing one `.env`:

1. **`api`** — HTTP API (uvicorn, 2 workers).
2. **`poller`** — drains the transcoder's completion SQS queue and writes
   `video-status` DynamoDB rows.

Lives at the repo root, a sibling of `../IAC/` (Terraform + dispatcher
Lambda + Fargate transcoder). It owns the infrastructure it runs *on*
(`terraform/` here: EC2, IAM, SG, ECR, SSM, thumbnails bucket, log group)
and nothing in the pipeline — those coordinates arrive via
`terraform_remote_state`. Deployed on its own cadence: the pipeline stack is
applied first, then this one.

## Layout

```
backend/
├── app/
│   ├── main.py                 FastAPI app + CORS + router mount + /healthz
│   ├── config.py               pydantic-settings; env first, then .env
│   ├── clients.py              lazy singletons: cognito, s3, sqs, ddb, redis
│   ├── crypto.py               HMAC-SHA256 secret_hash for Cognito app clients
│   ├── deps.py                 get_current_user (cookie -> GetUser, Bearer fallback)
│   ├── schemas.py              pydantic request/response models
│   ├── routers/
│   │   ├── auth.py             /auth/{signup,verify-otp,login,logout,me}
│   │   ├── upload.py           /upload/video/{url, url/thumbnail, save}
│   │   └── videos.py           /videos/{mine, {id}, {id}/progress}
│   └── workers/
│       └── completion_poller.py  SQS -> DDB drainer (its own container)
├── terraform/                  EC2 stack; see terraform/AGENTS.md
├── scripts/
│   ├── generate-env.sh         terraform state -> .env (+ --push-ssm)
│   ├── push-image.sh           buildx -> ECR
│   └── deploy.sh               runs ON the instance; SSM env -> pull -> compose up
├── systemd/
│   └── video-backend.service   oneshot unit wrapping deploy.sh
├── Dockerfile                  one image, both processes
├── docker-compose.yml          api + poller
├── requirements.txt
├── .env.example
├── deployment-guide.md
└── README.md
```

## Routes

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/auth/signup` | – | Cognito `sign_up` + put_item `users` |
| POST | `/auth/verify-otp` | – | Cognito `confirm_sign_up` |
| POST | `/auth/login` | – | Cognito `initiate_auth`, sets HTTPOnly cookies |
| POST | `/auth/logout` | – | Clears cookies |
| GET  | `/auth/me` | cookie | Cognito `GetUser` + DDB `users` GetItem |
| GET  | `/upload/video/url` | cookie | Presigned PUT for raw MP4 (key `videos/<sub>/<uuid>.mp4`) |
| GET  | `/upload/video/url/thumbnail` | cookie | Presigned PUT for thumbnail JPG |
| POST | `/upload/video/save` | cookie | `PutItem` on `video-status` (status=PROCESSING) |
| GET  | `/videos/mine` | cookie | GSI `uploader-created-index` query, newest first |
| GET  | `/videos/{video_id}` | – | GetItem |
| GET  | `/videos/{video_id}/progress` | – | Redis `GET video:progress:<id>` + DDB status |
| GET  | `/healthz` | – | Liveness |

## Config

All config is env-driven via `pydantic_settings.BaseSettings`. In containers
the values arrive as process environment (compose `env_file`), so the
`env_file=".env"` setting only matters for local runs.

`.env` is **generated, not hand-written** — `scripts/generate-env.sh` reads
the pipeline and backend Terraform states and fills in every infrastructure
value. Only Cognito credentials and policy knobs (CORS, cookies, TTLs) are
carried over from the previous file / environment / `.env.example`. If you
add a setting to `config.py`, add it to `.env.example` **and** to the emit
block in `generate-env.sh`, or it will be silently dropped on the next
regeneration.

Sensitive: `COGNITO_CLIENT_SECRET`. The whole `.env` is stored as an SSM
SecureString (`/video-backend/env`) and pulled by `deploy.sh` at start. It is
gitignored, written mode 600, and excluded by `.dockerignore` — never COPY it
into the image and never put it in Terraform.

## Data ownership

- **Cognito** owns identity + password + OTP. Backend never stores
  passwords.
- **DDB `users`** — mirror keyed by `cognito_sub`. Written on
  `/auth/signup` only. Read on `/auth/me` and joins.
- **DDB `video-status`** — video metadata + processing status. Written
  in two places only:
  - `POST /upload/video/save` writes initial row with
    `status=PROCESSING` (via `PutItem` with condition
    `attribute_not_exists(video_id)`).
  - `completion_poller` writes terminal status + `manifest_uri` +
    `error` (via idempotent `UpdateItem`).
- **Redis `video:progress:<id>`** — read-only for the backend.
  Transcoder is the sole writer. Never mint progress values in the
  backend.

## Auth flow (mirror of `../IAC/deployment-guide.md` and `../auth-implementation-guide.md`)

- App client MUST have a **client secret** and `USER_PASSWORD_AUTH`
  enabled — otherwise `initiate_auth` rejects the `SECRET_HASH`.
- HTTPOnly cookies are set on login. `Secure`/`SameSite` come from
  `.env` (`COOKIE_SECURE`, `COOKIE_SAMESITE`).
- `get_current_user` prefers the `access_token` cookie, falls back to
  `Authorization: Bearer <token>` for mobile clients that can't hold
  cookies. Both paths validate via Cognito `GetUser`.

## Poller worker

- Long-poll `receive_message` (10s, up to 10 msgs).
- For each message, JSON-parse and `UpdateItem` on `video-status`:

  ```
  SET status = <upper(status)>, manifest_uri = <m>, error = <e>, updated_at = <iso>
  ```

- On success → `delete_message`.
- On any exception → **do NOT** delete; SQS redelivers after visibility
  timeout, DLQ catches poison messages after `max_receive_count` (3 in
  terraform default).
- SIGINT/SIGTERM handled cleanly; compose gives it a 30s
  `stop_grace_period` so an in-flight batch finishes instead of going
  invisible until the timeout lapses.

## EC2 IAM (instance profile)

Defined in `terraform/iam.tf`, not by hand:

- `cognito-idp:{SignUp, ConfirmSignUp, InitiateAuth, GetUser}` on the
  user pool ARN (`var.cognito_user_pool_arn`).
- `dynamodb:{GetItem, PutItem, UpdateItem, Query}` on both tables and
  their `index/*`.
- `s3:PutObject` on `raw-bucket/videos/*` and `thumbnails-bucket/thumbnails/*`
  (grants the presigned URLs authority).
- `sqs:{ReceiveMessage, DeleteMessage, GetQueueAttributes}` on the
  completion queue.
- `ssm:GetParameter` + `kms:Decrypt` (scoped by `kms:ViaService`) for the
  `.env` parameter.
- ECR pull on the backend repo, `logs:{CreateLogStream, PutLogEvents}` on
  `/video-backend`, and `AmazonSSMManagedInstanceCore` for Session Manager.

The API server itself never uploads to S3; the presigned URL delegates
its permission to the client. Don't widen this policy — add a scoped
statement instead.

## Network

- The instance sits in the pipeline VPC. `terraform/network.tf` adds the
  ingress rule that opens Redis 6379 to this stack's SG; the pipeline stack
  is not edited for it. Do NOT expose Redis to the internet.
- The instance SG opens nothing inbound by default — shell access is SSM
  Session Manager. `api_ingress_cidrs` / `ssh_ingress_cidrs` are opt-in.
- Public traffic in via ALB or nginx; uvicorn runs with `--proxy-headers
  --forwarded-allow-ips '*'` so `X-Forwarded-Proto` drives `Secure` cookie
  issuance. That trusts forwarded headers unconditionally, so only put a
  proxy you control in front.

## Editing conventions

- Add a new endpoint → new function in the matching `routers/*.py`, add
  request/response models to `schemas.py`, register the router in
  `main.py` if it's a new file.
- Never inline `boto3.client(...)` — go through `clients.py` so tests
  and cold-start behavior stay consistent.
- Never write video status from HTTP handlers except the initial
  `POST /upload/video/save` — the poller owns terminal writes.
- Never log the `access_token` / `refresh_token` values.
- Cookies use `HttpOnly=True`, `Secure` toggled by config. Don't
  weaken them for local convenience — set `COOKIE_SECURE=false` in the
  dev `.env` instead.
- A new setting means three edits: `config.py`, `.env.example`, and the
  heredoc in `scripts/generate-env.sh`.
- New Python dependency → `requirements.txt` → rebuild and push the image.
  There is no venv on the instance.

## Local dev

```
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env    # point at dev cognito / dev ddb / dev sqs
uvicorn app.main:app --reload
python -m app.workers.completion_poller   # in another terminal
```

Container parity:

```
docker build -t video-backend:local .
docker compose up        # API on 127.0.0.1:8000
```

## Deploy

Full playbook in `deployment-guide.md`. High-level, pipeline already applied:

1. `cd terraform && terraform apply` — instance, IAM, SG, ECR, SSM param,
   thumbnails bucket, log group.
2. `scripts/push-image.sh` — buildx to ECR. Platform must match
   `cpu_architecture` (default arm64 / `t4g.small`).
3. `scripts/generate-env.sh --push-ssm` — needs `COGNITO_*` in the
   environment.
4. `sudo systemctl restart video-backend` over Session Manager.
5. `aws logs tail /video-backend --follow`.

Redeploy = steps 2 and 4. The instance is never rebuilt for a code or config
change.

**`docker-compose.yml`, `scripts/deploy.sh`, and `systemd/video-backend.service`
are baked into user_data** via `base64encode(file(...))`, and the instance has
`user_data_replace_on_change = true`. Editing any of those three replaces the
instance on the next apply. Everything else ships in the image.
