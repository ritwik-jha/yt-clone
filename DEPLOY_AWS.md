# Deploy to AWS — runbook for a local Claude Code session

Follow this file top to bottom to deploy the whole system to AWS with the
**`default` AWS CLI profile**:

1. the transcoding pipeline (`IAC/terraform`) and its transcoder image,
2. the backend (`backend/terraform`): API, poller and RDS,
3. the Flutter web app as an **ECS service** (`frontend/terraform`),

Then run an integration test against the live system. The result is the
**frontend URL**.

Everything is Terraform plus a few `docker` / `flutter` commands. The steps are
safe to re-run: if something fails half-way, fix it and continue from the
failed step.

```
                         Browser
                            │ https://<frontend>.on.aws
                            ▼
        ┌────────── ECS Express Mode (HTTPS ALB, AWS cert) ──────────┐
        │  video-frontend (nginx)               video-backend-api    │
        │   ├─ /            → Flutter web build    (FastAPI)          │
        │   └─ /auth/ /video/ /upload/ /healthz ──► https://<api>.on.aws
        └────────────────────────────────────────────────────────────┘
   presigned PUT ─► S3 raw ─► SQS ─► Lambda ─► Fargate transcoder ─► S3 processed ─► CloudFront (HLS/DASH)
                                                     │ SQS completion ─► video-backend-poller ─► RDS
```

The frontend's nginx forwards the API paths to the API. The browser
therefore sees one origin, which gives three properties:
- The auth cookies are first-party (`SameSite=Lax`).
- The API keeps `CORS_ORIGINS` empty.
- Nothing in the Flutter build needs the API's URL (`API_BASE_URL` is empty).

---

## 0. Rules for the session

- **Use only the `default` profile.** Every shell runs
  `source deploy-artifacts/env.sh`, which exports `AWS_PROFILE=default` and
  the region. Each Bash call is a fresh shell, so start **every** command
  block with that line. (Step 1 creates the file.)
- **Ask the user once before the first `terraform apply`.**
  - Show them the region, the account ID, and the resource summary from the
    three plans.
  - Tell them it will cost money while it runs (see §9).
  - After that, apply without asking again, unless a plan wants to
    **destroy or replace** something that already exists. In that case, stop
    and ask.
- **Never print secrets.** That includes the Cognito client secret, the DB
  secret value, and `terraform output cognito_user_pool_client_secret`.
- **Don't commit.**
  - `terraform.tfvars`, the state files and `deploy-artifacts/` are all
    gitignored.
  - Don't change application code to make a step pass; report the problem
    instead.
- **Diagnose failures.** If a step fails, use §8 (Troubleshooting) and the
  logs. Don't skip a step or a test, and don't lower a check to get green.
- **Keep a log.** Append what you did and each output to
  `deploy-artifacts/deploy-log.md` as you go.
- **Expect long waits.** The first deployment takes about **35–60 minutes**,
  mostly waiting on RDS, CloudFront and ElastiCache.

---

## 1. Preflight

### 1.1 Tools

Run each command and check the version:

| Tool | Check | Need |
|---|---|---|
| AWS CLI v2 | `aws --version` | 2.x |
| Terraform | `terraform version` | ≥ 1.5 (the stacks pin the AWS provider `~> 6.23`) |
| Docker with buildx, daemon running | `docker buildx version && docker info >/dev/null` | |
| Flutter (stable) | `flutter --version` | 3.47.x (Dart ≥ 3.13.5) |
| Python | `python3 --version` | ≥ 3.11 |
| ffmpeg | `ffmpeg -version` | any (makes the test video) |
| jq, curl, git | `jq --version` | any |

If one is missing, tell the user what to install and stop. Don't install
system packages without asking.

### 1.2 Repository

Run from the repository root. The code to deploy is this branch's code,
which contains the Flutter web frontend.

```bash
git status --short     # should be clean; report anything unexpected
git log --oneline -1
```

### 1.3 AWS identity, region and session file

```bash
export AWS_PROFILE=default
aws sts get-caller-identity          # must succeed; note Account and Arn

REGION="$(aws configure get region --profile default || true)"
REGION="${REGION:-ap-south-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
case "$(uname -m)" in
  arm64|aarch64) TRANSCODER_ARCH=ARM64;  TRANSCODER_PLATFORM=linux/arm64 ;;
  *)             TRANSCODER_ARCH=X86_64; TRANSCODER_PLATFORM=linux/amd64 ;;
esac

mkdir -p deploy-artifacts
cat > deploy-artifacts/env.sh <<EOF
# Sourced by every step of DEPLOY_AWS.md. Safe to re-source.
export AWS_PROFILE=default
export AWS_REGION=$REGION
export AWS_DEFAULT_REGION=$REGION
export ACCOUNT_ID=$ACCOUNT_ID
# Globally unique S3 names, derived from the account and region.
export NAME_SUFFIX=$ACCOUNT_ID-$REGION
# The transcoder is built for this machine's CPU, so no emulation is needed.
# The backend and frontend images are always linux/amd64, because Express Mode
# runs x86_64.
export TRANSCODER_ARCH=$TRANSCODER_ARCH
export TRANSCODER_PLATFORM=$TRANSCODER_PLATFORM
export REPO_ROOT=$(pwd)
EOF
cat deploy-artifacts/env.sh
```

If `deploy-artifacts/env.sh` already exists from an earlier run, keep it,
because the bucket names and tags in it are already in use. Only recreate
it if the account or region must change, and then ask the user first.

### 1.4 Permissions

The profile needs broad rights:
- Create and manage: VPC/EC2, S3, SQS, Lambda, ECS (including Express Mode),
  ECR, IAM roles and policies, ElastiCache, Cognito, CloudFront, RDS,
  Secrets Manager, SSM, CloudWatch Logs, ELB, ACM and Application Auto
  Scaling.
- Use `iam:PassRole` on the roles the stacks create.
- Call `cognito-idp:AdminConfirmSignUp` and `cognito-idp:AdminDeleteUser`
  (used by the test).

An administrator profile is simplest. If an apply fails with `AccessDenied`,
report the exact action to the user.

### 1.5 Local checks before deploying

These need no AWS. They run the backend, frontend and API tests against a
local SQLite backend.

```bash
source deploy-artifacts/env.sh
python3 -m venv deploy-artifacts/venv
deploy-artifacts/venv/bin/pip install -q -r backend/requirements-dev.txt playwright
export PATH="$REPO_ROOT/deploy-artifacts/venv/bin:$PATH"
scripts/run_pipeline.sh --only 1     # backend sanity
scripts/run_pipeline.sh --only 2     # flutter analyze + unit/widget tests + web build
scripts/run_pipeline.sh --only 3     # API integration
```

The browser E2E needs Chrome and a ChromeDriver with the same major
version. If both are installed, also run step 4:

```bash
source deploy-artifacts/env.sh
export PATH="$REPO_ROOT/deploy-artifacts/venv/bin:$PATH"
CHROME_EXECUTABLE=/path/to/chrome CHROMEDRIVER=/path/to/chromedriver scripts/run_pipeline.sh --only 4
```

If any of these fail, stop and report; don't deploy broken code.

---

## 2. Pipeline stack (`IAC/terraform`)

This stack creates:
- VPC and subnets,
- the raw and processed buckets,
- the SQS queues and their DLQs,
- the Lambda dispatcher,
- the ECS cluster and task definition for the transcoder,
- ElastiCache Redis,
- the Cognito user pool, and
- the playback CloudFront distribution.

### 2.1 Variables

```bash
source deploy-artifacts/env.sh
cd IAC/terraform
if [ ! -f terraform.tfvars ]; then
cat > terraform.tfvars <<EOF
aws_region            = "$AWS_REGION"
project_name          = "video-transcoder"
raw_bucket_name       = "ytclone-raw-$NAME_SUFFIX"
processed_bucket_name = "ytclone-processed-$NAME_SUFFIX"
cpu_architecture      = "$TRANSCODER_ARCH"
image_tag             = "latest"
tags = {
  Environment = "dev"
  Owner       = "yt-clone"
}
EOF
fi
cat terraform.tfvars
```

### 2.2 Plan

```bash
source deploy-artifacts/env.sh
cd IAC/terraform
terraform init -input=false
terraform plan -input=false -out=tfplan | tee "$REPO_ROOT/deploy-artifacts/plan-pipeline.txt" | tail -40
```

**This is where you ask the user for approval (§0).** Before asking:
1. Run `terraform init` for the backend and frontend directories too.
2. Explain that their plans can only be produced after this stack and the
   backend exist, because they read its state.
3. Summarise what all three stacks create:
   - **Pipeline:** the plan above.
   - **Backend:** RDS PostgreSQL `db.t4g.micro`, the API Express Mode
     service with its ALB, the poller service, IAM roles, the thumbnails
     bucket and its CloudFront distribution, and ECR.
   - **Frontend:** ECR, IAM roles, a security group, and the Express Mode
     service.

### 2.3 Apply

```bash
source deploy-artifacts/env.sh
cd IAC/terraform
terraform apply -input=false tfplan
terraform output | grep -v -i secret
```

The Lambda's image reference doesn't exist yet. That is expected until
step 3 runs.

---

## 3. Transcoder image

```bash
source deploy-artifacts/env.sh
cd IAC/transcoder
ECR_URL="$(terraform -chdir=../terraform output -raw ecr_repository_url)"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${ECR_URL%%/*}"
docker buildx build --platform "$TRANSCODER_PLATFORM" -t "$ECR_URL:latest" --push .
aws ecr describe-images --repository-name "${ECR_URL##*/}" --image-ids imageTag=latest \
  --query 'imageDetails[0].imagePushedAt'
```

ECS pulls `:latest` on every `RunTask`, so no Terraform change follows.

---

## 4. Backend stack (`backend/terraform`)

### 4.1 Variables

Same-origin hosting means the following settings:
- `cors_origins` stays empty.
- `cookie_samesite` stays `lax`.
- `cookie_secure` stays `true`, because both Express Mode endpoints are
  HTTPS.

```bash
source deploy-artifacts/env.sh
cd backend/terraform
if [ ! -f terraform.tfvars ]; then
cat > terraform.tfvars <<EOF
aws_region   = "$AWS_REGION"
project_name = "video-transcoder"
backend_name = "video-backend"

pipeline_state_backend    = "local"
pipeline_state_local_path = "../../IAC/terraform/terraform.tfstate"

thumbnails_bucket_name  = "ytclone-thumbs-$NAME_SUFFIX"
thumbnails_cors_origins = ["*"]

# The web app is served on its own origin and proxies the API (frontend/deploy),
# so the browser never calls the API cross-origin.
cors_origins    = []
cookie_secure   = true
cookie_samesite = "lax"

tags = {
  Environment = "dev"
  Owner       = "yt-clone"
}
EOF
fi
cat terraform.tfvars
```

### 4.2 ECR repository first, then the image

```bash
source deploy-artifacts/env.sh
cd backend/terraform
terraform init -input=false -upgrade
terraform apply -input=false -auto-approve \
  -target=aws_ecr_repository.backend -target=aws_ecr_lifecycle_policy.backend

BACKEND_TAG="$(git rev-parse --short HEAD)-$(date +%Y%m%d%H%M%S)"
echo "export BACKEND_TAG=$BACKEND_TAG" >> "$REPO_ROOT/deploy-artifacts/env.sh"
cd .. && scripts/push-image.sh "$BACKEND_TAG"
```

`-target` only creates the image repository, which is part of the stack the
user approved. Terraform warns that `-target` is for exceptional use; that
warning is expected here.

### 4.3 Plan and apply

```bash
source deploy-artifacts/env.sh
cd backend/terraform
terraform plan -input=false -var "image_tag=$BACKEND_TAG" -out=tfplan \
  | tee "$REPO_ROOT/deploy-artifacts/plan-backend.txt" | tail -40
terraform apply -input=false tfplan
```

The first apply takes 10–20 minutes, mostly for RDS, the thumbnails
CloudFront distribution, and Express Mode's ALB and certificate. The API
resource waits until its tasks pass the `/healthz` check, and each API task
runs the Alembic migrations before it serves.

### 4.4 Verify

```bash
source deploy-artifacts/env.sh
cd backend/terraform
API_URL="$(terraform output -raw api_url)"
for i in $(seq 1 30); do curl -fsS "$API_URL/healthz" && break; sleep 10; done; echo
aws ecs describe-services --cluster "$(terraform output -raw ecs_cluster)" \
  --services "$(terraform output -raw poller_service_name)" \
  --query 'services[0].{running:runningCount,desired:desiredCount}'
```

Expect `{"status":"ok"}`, and the poller should show `running` equal to
`desired`. Write `API_URL` into the log.

---

## 5. Frontend on ECS (`frontend/terraform`)

What gets deployed:
- **Container:** `frontend/deploy/Dockerfile` (nginx with the Flutter web
  build). `frontend/deploy/nginx.conf.template` serves the app, with
  `index.html` as the fallback for app routes, and forwards
  `/auth/`, `/video/`, `/upload/` and `/healthz` to the API.
- **Infrastructure:** `frontend/terraform/` puts it on an **ECS Express Mode
  service** in the backend's cluster. Express Mode gives it an HTTPS ALB with
  an AWS certificate and a `*.on.aws` URL. The container health check is
  `/_health`.

### 5.1 Build the web app

`--no-web-resources-cdn` bundles CanvasKit into the build instead of
loading it from Google's CDN, so the container is self-contained.
`env/prod.json.example` has an empty `API_BASE_URL`, so the app calls its own
origin.

```bash
source deploy-artifacts/env.sh
cd frontend
flutter pub get
git checkout -- analysis_options.yaml 2>/dev/null || true   # pub get may rewrite it
flutter build web --release --no-web-resources-cdn --dart-define-from-file=env/prod.json.example
ls build/web/index.html build/web/canvaskit/canvaskit.wasm build/web/vendor
```

### 5.2 ECR repository, then the image

```bash
source deploy-artifacts/env.sh
cd frontend/terraform
[ -f terraform.tfvars ] || cat > terraform.tfvars <<EOF
aws_region    = "$AWS_REGION"
frontend_name = "video-frontend"
tags = {
  Environment = "dev"
  Owner       = "yt-clone"
}
EOF
terraform init -input=false
terraform apply -input=false -auto-approve \
  -target=aws_ecr_repository.frontend -target=aws_ecr_lifecycle_policy.frontend

FRONTEND_TAG="$(git rev-parse --short HEAD)-$(date +%Y%m%d%H%M%S)"
echo "export FRONTEND_TAG=$FRONTEND_TAG" >> "$REPO_ROOT/deploy-artifacts/env.sh"
ECR_URL="$(terraform output -raw ecr_repository_url)"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${ECR_URL%%/*}"
cd ..   # frontend/ is the build context
docker buildx build --platform linux/amd64 -f deploy/Dockerfile -t "$ECR_URL:$FRONTEND_TAG" --push .
```

### 5.3 Plan and apply

```bash
source deploy-artifacts/env.sh
cd frontend/terraform
terraform plan -input=false -var "image_tag=$FRONTEND_TAG" -out=tfplan \
  | tee "$REPO_ROOT/deploy-artifacts/plan-frontend.txt" | tail -30
terraform apply -input=false tfplan
terraform output
```

### 5.4 Verify

```bash
source deploy-artifacts/env.sh
FRONTEND_URL="$(terraform -chdir=frontend/terraform output -raw frontend_url)"
echo "export FRONTEND_URL=$FRONTEND_URL" >> deploy-artifacts/env.sh
for i in $(seq 1 30); do curl -fsS "$FRONTEND_URL/_health" && break; sleep 10; done
curl -fsS "$FRONTEND_URL/healthz"; echo                 # the API, through nginx
curl -fsS -o /dev/null -w '%{http_code} %{content_type}\n' "$FRONTEND_URL/watch?v=x"   # 200 text/html
```

A new `*.on.aws` name can take a minute or two to resolve. The loop allows
for that.

---

## 6. Integration test against the live system

`scripts/deploy_smoke_test.py` runs about 60 checks through the frontend URL,
the way a browser would:

| Area | Checks |
|---|---|
| Static app | The app is served; app routes fall back to `index.html`, including `/upload` and `/channel/...`, which stay with the app; the player libraries load |
| API through the frontend origin | `/healthz`, the feed (latest and popular), search, and a 401 when signed out |
| Accounts | A throwaway account `deploy-smoke+<stamp>@example.com` signs up and is confirmed with `AdminConfirmSignUp`, because real Cognito emails a code. Then sign-in, with the cookie attributes checked (HttpOnly, Secure, refresh token on `Path=/auth`, host-only), then `/auth/me` and refresh |
| Upload | A 6-second H.264 MP4 and a JPEG made with ffmpeg; presigned URLs; the S3 CORS preflight; PUTs to S3; save. The video appears in *Your videos* |
| Pipeline | Polls `/video/{id}/progress` until `COMPLETED` (15-minute limit). Covers S3 → SQS → Lambda → Fargate → SQS → poller → RDS |
| Playback | `hls_url`, `manifest_url` and the thumbnail load from CloudFront with CORS headers; the HLS master and media playlists and the first segment load |
| Listings | Feed, search, channel, a view count, and editing the title |
| Browser (`--browser`) | Headless Chromium loads the app and its feed. The watch page fetches the HLS playlist. Screenshots are saved to `deploy-artifacts/` |
| Cleanup | Deletes the video, signs out, and deletes the Cognito user. The `users` row stays, because there is no API to remove it |

```bash
source deploy-artifacts/env.sh
export PATH="$REPO_ROOT/deploy-artifacts/venv/bin:$PATH"
python3 -m playwright install chromium        # once; skip if already installed
POOL_ID="$(terraform -chdir=IAC/terraform output -raw cognito_user_pool_id)"
python3 scripts/deploy_smoke_test.py "$FRONTEND_URL" \
  --user-pool-id "$POOL_ID" --region "$AWS_REGION" \
  --browser --artifacts deploy-artifacts
```

Notes on these flags and outputs:
- **Exit status:** `0` means every check passed. The full report is in
  `deploy-artifacts/smoke-report.json`.
- **`--keep`:** leaves the test video and account in place, so the site
  isn't empty when the user opens it. Mention it if the user wants a demo
  video.
- **`--chromium /path/to/chrome`:** use this if Playwright's own Chromium
  can't be installed.
- **The first transcode** is usually 2–5 minutes, including the cold start
  of the Fargate task.
- **Playback in Playwright:** its bundled Chromium has no H.264 decoder, so
  the browser check confirms that the HLS playlist is fetched, not that
  video plays. Opening the URL in Chrome, Edge, Firefox or Safari plays it.

After the test, look at `deploy-artifacts/home.png` and
`deploy-artifacts/watch.png`. They should match the app's dark,
YouTube-style layout.

---

## 7. Report back to the user

Finish with a short summary in this shape. Also save it as
`deploy-artifacts/deploy-summary.md`.

```
Frontend URL:  https://<...>.on.aws          ← the deliverable
API URL:       https://<...>.on.aws           (also reachable through the frontend)
Playback CDN:  https://<cloudfront_domain_name>
Region / account: <region> / <account>
Images: backend <BACKEND_TAG>, frontend <FRONTEND_TAG>, transcoder latest
Integration test: PASSED n/n (deploy-artifacts/smoke-report.json)
Teardown: see DEPLOY_AWS.md §10
```

Get the values with:

```bash
source deploy-artifacts/env.sh
terraform -chdir=frontend/terraform output -raw frontend_url; echo
terraform -chdir=backend/terraform output -raw api_url; echo
terraform -chdir=IAC/terraform output -raw cloudfront_domain_name; echo
```

---

## 8. Troubleshooting

| Symptom | Look at / fix |
|---|---|
| `BucketAlreadyExists` on the pipeline or backend apply | The name is taken in another account. Change `NAME_SUFFIX` in `deploy-artifacts/env.sh` (e.g. append `-2`), delete the stack's `terraform.tfvars` and redo its §x.1 |
| `aws_ecs_express_gateway_service` is an unknown resource type | Run `terraform init -upgrade` in that stack (provider must be ≥ 6.23) |
| `Error acquiring the state lock` | Another terraform is running; wait. If it was killed, `terraform force-unlock <id>` after confirming nothing runs |
| Express Mode apply waits forever / tasks keep stopping | `aws logs tail /video-backend --since 15m` or `aws logs tail /video-frontend --since 15m`; `aws ecs list-tasks --cluster video-backend --desired-status STOPPED` then `aws ecs describe-tasks ... --query 'tasks[].stoppedReason'` |
| `exec format error` in the task log | Image built for the wrong CPU. Backend and frontend must be `linux/amd64`; the transcoder must match `TRANSCODER_ARCH` |
| API task fails on start with a migration error | API log stream `api/...`; usually DB reachability or a failed revision. Don't edit migrations to pass |
| Frontend `/healthz` or `/auth/...` returns 502/504 | nginx can't reach the API: `aws logs tail /video-frontend --since 10m` (look for `upstream`/`SSL`). Check `terraform -chdir=frontend/terraform output api_url` answers `/healthz` directly. If the API URL changed, re-apply the frontend stack |
| Sign-in succeeds but the next call is anonymous | The browser didn't store the cookie. It must be the frontend's HTTPS URL (Secure cookies). Check the `Set-Cookie` headers on `POST $FRONTEND_URL/auth/login` |
| `AccessDenied` for `AdminConfirmSignUp` in the test | The profile lacks Cognito admin rights; report it |
| Video stays `PENDING` | Lambda: `aws logs tail /aws/lambda/video-transcoder-dispatcher --since 15m`. Transcoder: `aws logs tail /ecs/video-transcoder --since 15m` (image missing? → §3). Poller: `aws logs tail /video-backend --since 15m --filter-pattern poller` |
| Video goes `FAILED` | Transcoder log for the ffmpeg error |
| CloudFront 403/404 on manifests right after the first apply | The distribution may still be deploying: `aws cloudfront get-distribution --id $(terraform -chdir=IAC/terraform output -raw cloudfront_distribution_id) --query Distribution.Status` must be `Deployed` |
| Upload PUT 403 | Clock skew or an expired URL; re-run. The test sends exactly `video/mp4` / `image/jpeg` |
| Docker push: `no basic auth credentials` / `403` | ECR login expired (12 h); re-run the `get-login-password` line |
| `python3 -m playwright install chromium` can't download | Pass `--chromium` with a local Chrome/Chromium, or drop `--browser` and say so in the report |
| Reload of `/watch?...` shows an nginx 404 | The image was built without `deploy/nginx.conf.template`; rebuild from `frontend/` with `-f deploy/Dockerfile` |

---

## 9. Cost

While deployed, these resources bill continuously:
- the RDS instance,
- ElastiCache Serverless,
- the Express Mode ALB,
- three always-on Fargate tasks (API, poller, frontend),
- CloudWatch logs,
- small S3 and CloudFront charges.

ElastiCache, RDS and the ALB dominate. Expect tens to a few hundred USD per
month, so tear it down when the user is done (§10). The transcoder only
bills per upload.

---

## 10. Updating and teardown

**Ship new code.** Rebuild, push a **new** tag, and apply with it. A reused
tag doesn't change the task definition, so nothing restarts.

| What | Commands |
|---|---|
| Backend | `cd backend && scripts/push-image.sh <tag> && terraform -chdir=terraform apply -var image_tag=<tag>` |
| Frontend | §5.1 build → `docker buildx build ... -t $ECR_URL:<tag> --push .` → `terraform -chdir=frontend/terraform apply -var image_tag=<tag>` |
| Transcoder | §3 (ECS pulls `:latest` on the next upload) |

**Teardown.** Only do this when the user asks, and confirm first. Run the
stacks in reverse order:

```bash
source deploy-artifacts/env.sh

# 1. Frontend
terraform -chdir=frontend/terraform destroy -input=false -var "image_tag=$FRONTEND_TAG"

# 2. Backend. RDS has deletion protection, so turn it off first. The destroy
#    keeps a final snapshot named video-backend-final; it holds all users and videos.
terraform -chdir=backend/terraform apply   -input=false -var "image_tag=$BACKEND_TAG" -var db_deletion_protection=false
aws ecr batch-delete-image --repository-name video-backend \
  --image-ids "$(aws ecr list-images --repository-name video-backend --query 'imageIds[*]' --output json)" || true
terraform -chdir=backend/terraform destroy -input=false -var "image_tag=$BACKEND_TAG" -var db_deletion_protection=false

# 3. Pipeline (the ECR repo isn't force-deleted)
REPO="$(terraform -chdir=IAC/terraform output -raw ecr_repository_url)"; REPO="${REPO##*/}"
aws ecr batch-delete-image --repository-name "$REPO" \
  --image-ids "$(aws ecr list-images --repository-name "$REPO" --query 'imageIds[*]' --output json)" || true
terraform -chdir=IAC/terraform destroy -input=false
```

Afterwards, tell the user that the `video-backend-final` RDS snapshot still
exists. They can delete it with
`aws rds delete-db-snapshot --db-snapshot-identifier video-backend-final`
when it's no longer needed.
