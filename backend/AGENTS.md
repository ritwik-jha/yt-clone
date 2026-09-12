# AGENTS.md — backend (FastAPI on EC2)

FastAPI gateway for the video platform. Two long-lived processes on one
EC2 instance sharing one venv + one `.env`:

1. **`backend.service`** — HTTP API (uvicorn 2 workers).
2. **`completion-poller.service`** — drains the transcoder's completion
   SQS queue and writes `video-status` DynamoDB rows.

## Layout

```
backend/
├── app/
│   ├── main.py                 FastAPI app + CORS + router mount + /healthz
│   ├── config.py               pydantic-settings; loaded via .env at process start
│   ├── clients.py              lazy singletons: cognito, s3, sqs, ddb, redis
│   ├── crypto.py               HMAC-SHA256 secret_hash for Cognito app clients
│   ├── deps.py                 get_current_user (cookie -> GetUser, Bearer fallback)
│   ├── schemas.py              pydantic request/response models
│   ├── routers/
│   │   ├── auth.py             /auth/{signup,verify-otp,login,logout,me}
│   │   ├── upload.py           /upload/video/{url, url/thumbnail, save}
│   │   └── videos.py           /videos/{mine, {id}, {id}/progress}
│   └── workers/
│       └── completion_poller.py  SQS -> DDB drainer (its own process)
├── systemd/
│   ├── backend.service
│   └── completion-poller.service
├── requirements.txt
├── .env.example
└── README.md                   EC2 deploy walkthrough + IAM policy
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

All config is env-driven via `pydantic_settings.BaseSettings` with
`env_file=".env"`. See `.env.example` for the exhaustive list and the
mapping table in `README.md` for which terraform output populates each.

Sensitive: `COGNITO_CLIENT_SECRET`. Everything else is public-ish and
can live in the systemd `EnvironmentFile` unrotated.

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

## Auth flow (mirror of `../deployment-guide.md` and `auth-implementation-guide.md`)

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
- SIGINT/SIGTERM handled cleanly for `systemctl stop`.

## EC2 IAM (instance profile)

Documented as a copy-pasteable JSON policy in `README.md`. Summary:

- `cognito-idp:{SignUp, ConfirmSignUp, InitiateAuth, GetUser}` on the
  user pool ARN.
- `dynamodb:{GetItem, PutItem, UpdateItem, Query}` on both tables and
  their `index/*`.
- `s3:PutObject` on the raw + thumbnail bucket prefixes (grants the
  presigned URLs authority).
- `sqs:{ReceiveMessage, DeleteMessage, GetQueueAttributes}` on the
  completion queue.

The API server itself never uploads to S3; the presigned URL delegates
its permission to the client.

## Network

- The instance MUST reach Redis. Either place the instance in the
  pipeline VPC and add its SG to the redis SG's ingress, or VPC-peer +
  route. Do NOT expose Redis to the internet.
- Public traffic in via ALB or nginx; run uvicorn with `--proxy-headers`
  so `X-Forwarded-Proto` drives `Secure` cookie issuance.

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

## Local dev

```
cd IAC/backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env    # point at dev cognito / dev ddb / dev sqs
uvicorn app.main:app --reload
python -m app.workers.completion_poller   # in another terminal
```

## Deploy

Full playbook in `README.md` §EC2 Deployment. High-level:

1. Provision EC2 + instance profile (IAM policy in README) + SGs.
2. `scp` the `backend/` folder to `/opt/video-backend`.
3. `python3 -m venv .venv && .venv/bin/pip install -r requirements.txt`.
4. Fill `.env` from terraform outputs (mapping table in README).
5. `cp systemd/*.service /etc/systemd/system/ && systemctl enable --now backend completion-poller`.
6. `curl /healthz` and tail `journalctl -u backend -u completion-poller -f`.
