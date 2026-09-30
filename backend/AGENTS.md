# AGENTS.md — backend (FastAPI on ECS Fargate)

FastAPI gateway for the video platform. Two ECS services built from a single
image:

1. **`api`** — HTTP API (uvicorn, 2 workers). ECS Express Mode service behind
   the internet-facing HTTPS ALB that Express Mode creates.
2. **`poller`** — plain Fargate service. Drains the transcoder's completion
   SQS queue and writes `video-status` DynamoDB rows.

Lives at the repo root, a sibling of `../IAC/` (Terraform + dispatcher
Lambda + Fargate transcoder). It owns the infrastructure it runs *on*
(`terraform/` here: ECS cluster and services, IAM, SGs, ECR, thumbnails
bucket, log group)
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
├── terraform/                  ECS stack; see terraform/AGENTS.md
├── scripts/
│   ├── generate-env.sh         terraform state -> .env (local dev only)
│   └── push-image.sh           buildx (linux/amd64) -> ECR
├── Dockerfile                  one image, both processes
├── docker-compose.yml          api + poller, local parity only
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

All config is env-driven via `pydantic_settings.BaseSettings`.

- **ECS:** task environment comes from `local.api_environment` /
  `local.poller_environment` in `terraform/ecs.tf`, built from both stacks'
  state. There is no `.env` in production.
- **Local:** `scripts/generate-env.sh` writes `.env` from the same Terraform
  states. Policy knobs (CORS, cookies, TTLs) are carried over from the
  previous file / environment / `.env.example`.

Settings default to empty, and each entrypoint calls `Settings.require(...)`
for the ones it needs: `main.py` for Cognito, buckets, and Redis; the poller
for `COMPLETION_QUEUE_URL` and `CLOUDFRONT_DOMAIN`. A missing value fails at
startup, not on first request.

Sensitive: `COGNITO_CLIENT_SECRET`. In ECS it is injected from the pipeline's
SSM SecureString (`/<project>/cognito/client-secret`) via the container
`secret` block, and only the API execution role can read it. The local `.env`
is gitignored, written mode 600, and excluded by `.dockerignore`. Never COPY
it into the image.

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
  - `completion_poller` writes terminal status + `manifest_key` +
    `manifest_url` + `error` (via idempotent `UpdateItem`).
- **Redis `video:progress:<id>`** — read-only for the backend.
  Transcoder is the sole writer. Never mint progress values in the
  backend.

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
- For each message, JSON-parse and `UpdateItem` on `video-status`:

  ```
  SET status = <upper(status)>, manifest_key = <k>, manifest_url = <m>, error = <e>, updated_at = <iso>
  ```

  The transcoder sends `manifest_uri` as `s3://<processed>/<key>`. The poller
  stores the key and `https://<CLOUDFRONT_DOMAIN>/<key>`. Clients play
  `manifest_url`; the processed bucket is private and CloudFront reads it
  through OAC.

- On success → `delete_message`.
- On any exception → **do NOT** delete; SQS redelivers after visibility
  timeout, DLQ catches poison messages after `max_receive_count` (3 in
  terraform default).
- SIGINT/SIGTERM handled cleanly; the task definition sets a 30s
  `stopTimeout` (compose: `stop_grace_period`) so an in-flight batch finishes
  instead of going invisible until the timeout lapses.

## IAM

Defined in `terraform/iam.tf`, not by hand. Each service has its own pair:

- **API execution role** — ECR pull, logs on `/video-backend`,
  `ssm:GetParameters` on the Cognito client-secret parameter.
- **API task role** — `cognito-idp:{SignUp, ConfirmSignUp, InitiateAuth,
  GetUser}` on the user pool; `dynamodb:{GetItem, PutItem, Query}` on both
  tables and their `index/*`; `s3:PutObject` on `raw-bucket/videos/*` and
  `thumbnails-bucket/thumbnails/*` (the presigned URLs' authority).
- **Poller execution role** — ECR pull and logs only.
- **Poller task role** — `sqs:{ReceiveMessage, DeleteMessage,
  GetQueueAttributes}` on the completion queue; `dynamodb:UpdateItem` on
  `video-status`.
- **Express infrastructure role** — `AmazonECSInfrastructureRoleforExpressGatewayServices`,
  used by ECS to manage the API's ALB, cert, SGs, and autoscaling.

The API server itself never uploads to S3; the presigned URL delegates
its permission to the client. Don't widen these policies — add a scoped
statement to the one role that needs it.

## Network

- Both services run in the pipeline VPC's public subnets with public IPs
  (there is no NAT). `terraform/network.tf` adds the ingress rule that opens
  Redis 6379 to the API SG only; the pipeline stack is not edited for it.
  Do NOT expose Redis to the internet.
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
- Never inline `boto3.client(...)` — go through `clients.py` so tests
  and cold-start behavior stay consistent.
- Never write video status from HTTP handlers except the initial
  `POST /upload/video/save` — the poller owns terminal writes.
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

1. First time only: `cd terraform && terraform init -upgrade &&
   terraform apply -target=aws_ecr_repository.backend`, so there is a repo to
   push to before the services exist.
2. `scripts/push-image.sh <tag>` — buildx `linux/amd64` to ECR.
3. `cd terraform && terraform apply -var image_tag=<tag>` — cluster, both
   services, IAM, SGs, thumbnails bucket, log group. Waits for the API to be
   healthy.
4. `aws logs tail /video-backend --follow`.

Redeploy = steps 2 and 3 with a new tag.
