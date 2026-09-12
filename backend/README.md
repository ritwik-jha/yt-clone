# Video Platform Backend (FastAPI, EC2)

FastAPI service that fronts the video transcoding pipeline. Two long-lived
processes on one EC2 instance:

1. **`backend.service`** — HTTP API (`uvicorn app.main:app`)
2. **`completion-poller.service`** — drains the transcoder's SQS completion
   queue and writes DynamoDB (`app.workers.completion_poller`)

Both share the same `.env` and the same virtualenv.

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
├── systemd/
│   ├── backend.service
│   └── completion-poller.service
├── requirements.txt
├── .env.example
└── README.md
```

---

## Assumptions / Placeholders

Everything in `.env.example` is a placeholder — copy to `.env` on the EC2
instance and fill in real values. Terraform outputs from `IAC/terraform/`
supply most of them:

| .env variable | Where from |
|---|---|
| `COGNITO_USER_POOL_ID`, `COGNITO_CLIENT_ID`, `COGNITO_CLIENT_SECRET` | AWS Console → Cognito user pool + app client (with a client secret) |
| `DDB_VIDEOS_TABLE` | `terraform output -raw dynamodb_table` (default: `video-status`) |
| `DDB_USERS_TABLE` | `terraform output -raw dynamodb_users_table` (default: `users`) |
| `S3_RAW_VIDEOS_BUCKET` | `terraform output -raw raw_bucket` |
| `S3_THUMBNAILS_BUCKET` | separate bucket you provision (not in the pipeline TF) |
| `COMPLETION_QUEUE_URL` | `terraform output -raw completion_queue_url` |
| `REDIS_HOST` / `REDIS_PORT` | parse from `terraform output -raw redis_endpoint` |
| `AWS_REGION` | `terraform output -raw aws_region` |

Cognito is **not** created by the pipeline Terraform — provision the user
pool + app client manually or in a separate module. The app client MUST
have a client secret and `USER_PASSWORD_AUTH` enabled.

---

## EC2 Deployment

Target: Ubuntu 22.04 / 24.04 on `t3.small` or larger. Instance must be able
to reach Redis (put it in the same VPC as the pipeline or peer/attach).

### 1. Instance IAM role

Attach an EC2 instance profile with a policy granting (scope to real ARNs):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["cognito-idp:SignUp", "cognito-idp:ConfirmSignUp",
                 "cognito-idp:InitiateAuth", "cognito-idp:GetUser"],
      "Resource": "arn:aws:cognito-idp:<region>:<acct>:userpool/<pool-id>" },

    { "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem",
                 "dynamodb:Query"],
      "Resource": [
        "arn:aws:dynamodb:<region>:<acct>:table/video-status",
        "arn:aws:dynamodb:<region>:<acct>:table/video-status/index/*",
        "arn:aws:dynamodb:<region>:<acct>:table/users",
        "arn:aws:dynamodb:<region>:<acct>:table/users/index/*"
      ] },

    { "Effect": "Allow",
      "Action": ["s3:PutObject"],
      "Resource": [
        "arn:aws:s3:::<raw-bucket>/videos/*",
        "arn:aws:s3:::<thumb-bucket>/thumbnails/*"
      ] },

    { "Effect": "Allow",
      "Action": ["sqs:ReceiveMessage", "sqs:DeleteMessage",
                 "sqs:GetQueueAttributes"],
      "Resource": "arn:aws:sqs:<region>:<acct>:video-completion-queue" }
  ]
}
```

Note: `s3:PutObject` is granted so the *presigned URLs* the API mints have
authority. The client uses the presigned URL — the API server itself never
uploads.

### 2. Security groups

- Backend EC2 SG: inbound 80/443 from ALB (or 8000 from your admin CIDR
  for direct testing), outbound all.
- Add this SG to the pipeline Redis SG's ingress rule so port 6379 opens
  up. In `IAC/terraform/network.tf` you can extend
  `aws_security_group.redis` with an extra `ingress` block referencing the
  backend SG, or use `aws_security_group_rule` from a separate module.

### 3. Provisioning steps on the instance

```bash
# 1. Copy the backend/ folder to the instance
scp -r IAC/backend ubuntu@<ec2-host>:/tmp/

ssh ubuntu@<ec2-host>
sudo mv /tmp/backend /opt/video-backend
cd /opt/video-backend

# 2. Python venv
sudo apt-get update && sudo apt-get install -y python3-venv
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

# 3. Env
cp .env.example .env
vi .env   # fill in cognito/ddb/s3/sqs/redis values from terraform outputs

# 4. Install systemd units
sudo cp systemd/backend.service          /etc/systemd/system/
sudo cp systemd/completion-poller.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now backend completion-poller

# 5. Verify
curl http://localhost:8000/healthz
sudo journalctl -u backend -f
sudo journalctl -u completion-poller -f
```

### 4. TLS

For production put an ALB or Nginx + Let's Encrypt in front. Uvicorn is
started with `--proxy-headers` so it honors `X-Forwarded-Proto` when
issuing `Secure` cookies.

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
cd IAC/backend
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
