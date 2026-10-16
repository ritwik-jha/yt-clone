# Deploy to AWS — runbook for a local Claude Code session

Follow this file top to bottom to deploy the whole system to AWS with the
**`default` AWS CLI profile**:

1. the transcoding pipeline (`IAC/terraform`) and its transcoder image,
2. the backend (`backend/terraform`): API, poller and RDS,
3. the Flutter web app as an **ECS service** (`frontend/terraform`),

Then run an integration test against the live system. The result is the
**frontend URL**. §11 tears all of it down again when the user asks.

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
- **Teardown (§11) needs its own confirmation** (§11.2), even if the user
  approved the deploy.
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
  mostly waiting on RDS, CloudFront and ElastiCache. A single stack's
  `terraform apply` (including a destroy) can run 10–25 minutes. That is
  longer than the Bash tool's 10-minute limit.
  - Start every `terraform apply` with the Bash tool's
    `run_in_background: true`, and wait for the completion notice before the
    next step.
  - Never kill a running `terraform`: that leaves a stale lock and a state
    that disagrees with AWS.
  - If a shell died anyway, check `pgrep -fl terraform` and
    `terraform state list` before re-running.

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
Teardown: see DEPLOY_AWS.md §11
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
month, so tear it down when the user is done (§11). The transcoder only
bills per upload.

---

## 10. Updating

**Ship new code.** Rebuild, push a **new** tag, and apply with it. A reused
tag doesn't change the task definition, so nothing restarts.

| What | Commands |
|---|---|
| Backend | `cd backend && scripts/push-image.sh <tag> && terraform -chdir=terraform apply -var image_tag=<tag>` |
| Frontend | §5.1 build → `docker buildx build ... -t $ECR_URL:<tag> --push .` → `terraform -chdir=frontend/terraform apply -var image_tag=<tag>` |
| Transcoder | §3 (ECS pulls `:latest` on the next upload) |

---

## 11. Teardown

Removes **everything** the runbook created, across all three stacks. Only do
this when the user asks for it, and only after the confirmation in §11.2.
Approval to deploy does not cover this.

**What is permanently deleted:**
- every uploaded and transcoded video (both S3 buckets are `force_destroy`);
- the thumbnails bucket;
- the Cognito user pool, so every account is gone;
- the ElastiCache progress cache;
- the SQS queues;
- all ECR images;
- the CloudWatch logs.

**What survives:**
- The RDS final snapshot `video-backend-final`. Terraform always takes it
  before deleting the database. It holds the users and videos tables. The
  user chooses in §11.2 whether to keep it or delete it.
- Local files: the empty Terraform state files, the `terraform.tfvars`
  files and `deploy-artifacts/`. See §11.8.

**Order: frontend → backend → pipeline.** This is the reverse of
deployment, and it is mandatory. The frontend stack reads the backend's and
the pipeline's state, and the backend reads the pipeline's. The backend's RDS
instance, security groups and Express Mode ALB all live in the pipeline's VPC.

**What would block a plain `terraform destroy`:**

| Blocker | Handled in |
|---|---|
| RDS `deletion_protection` (on by default) | §11.4: a targeted apply turns it off first |
| A snapshot named `video-backend-final` already exists from an earlier teardown | §11.1 check, §11.2 question |
| The backend and transcoder ECR repos aren't force-deleted, so they must be empty | §11.4, §11.5 (`empty_ecr`) |
| Transcoder tasks still running in the pipeline cluster | §11.5: stopped first |
| Express Mode removes its managed ALB, target groups and security group asynchronously, and they sit in the pipeline's VPC | §11.5: wait until the VPC is clear |
| Cognito `deletion_protection = ACTIVE`, if someone set it | §11.1 check, §11.5 |
| Container Insights log groups aren't managed by Terraform | §11.6 |

**Duration:** about 30–50 minutes. Most of it is the two CloudFront
distributions, RDS (which also writes the final snapshot), ElastiCache and
Express Mode draining. Run every `terraform apply` below in the background
(§0) and wait for it to exit.

### 11.1 Preflight and inventory

Each Bash call is a fresh shell, so the helpers go in a file that later
steps source:

```bash
source deploy-artifacts/env.sh
cat > deploy-artifacts/teardown-lib.sh <<'EOF'
# Helpers for DEPLOY_AWS.md §11. Source after env.sh.

# A variable's effective value in a stack (tfvars, else default).
tfvar() { echo "var.$2" | terraform -chdir="$1" console 2>/dev/null | tr -d '"'; }

# Resources in a stack's state (0 when it has none).
state_count() { terraform -chdir="$1" state list 2>/dev/null | wc -l | tr -d ' '; }

# Delete every image in an ECR repo so Terraform can delete the repo.
# Image indexes go before the manifests they reference, hence the rounds.
empty_ecr() {
  local repo="$1" ids n=0
  [ -n "$repo" ] || return 0
  while [ "$n" -lt 20 ]; do
    if ! ids="$(aws ecr list-images --repository-name "$repo" --max-items 100 \
                  --query 'imageIds' --output json 2>&1)"; then
      if grep -q RepositoryNotFound <<<"$ids"; then echo "ECR $repo: gone"; return 0; fi
      echo "$ids" >&2; return 1
    fi
    if [ -z "$ids" ] || [ "$ids" = "[]" ]; then echo "ECR $repo: empty"; return 0; fi
    aws ecr batch-delete-image --repository-name "$repo" --image-ids "$ids" \
      --query '{deleted: length(imageIds), failed: length(failures)}' --output text
    n=$((n + 1))
  done
  echo "ECR $repo still has images after $n rounds" >&2
  return 1
}

# Wait (up to 9 minutes) until no load balancer and no ELB/ECS-task ENI is
# left in the VPC. ElastiCache's ENIs are expected; Terraform removes them.
wait_vpc_clear() {
  local vpc="$1" i lbs enis
  [ -n "$vpc" ] || return 0
  for i in $(seq 1 18); do
    lbs="$(aws elbv2 describe-load-balancers \
             --query "length(LoadBalancers[?VpcId=='$vpc'])" --output text)"
    enis="$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc" \
             --query "length(NetworkInterfaces[?starts_with(not_null(Description,''),'ELB ') || starts_with(not_null(Description,''),'arn:aws:ecs:')])" \
             --output text)"
    echo "$(date +%T) load balancers=$lbs ELB/ECS ENIs=$enis"
    if [ "$lbs" = 0 ] && [ "$enis" = 0 ]; then return 0; fi
    sleep 30
  done
  return 1
}

# gone <label> <id> <describe command...>: passes when AWS says not found.
gone() {
  local label="$1" id="$2" out; shift 2
  if [ -z "$id" ]; then echo "skip     $label (never created)"; return; fi
  if out="$("$@" 2>&1)"; then echo "LEFT     $label ($id)"; return; fi
  if grep -qiE 'not ?found|does not exist|nonexistent|NoSuch|\(404\)' <<<"$out"; then
    echo "gone     $label"
  else
    echo "CHECK    $label ($id): $(head -n1 <<<"$out")"
  fi
}

# none <label> <list command...>: passes when the query prints nothing.
none() {
  local label="$1" out; shift
  out="$("$@" 2>&1)"
  case "$out" in
    ""|None|"[]"|0) echo "gone     $label" ;;
    *) echo "LEFT     $label: $(tr '\n' ' ' <<<"$out")" ;;
  esac
}
EOF
echo ok
```

Check that the account is the one that was deployed to, and initialise the
three stacks. In a fresh clone `.terraform/` is missing, but the state files
are not:

```bash
source deploy-artifacts/env.sh
[ "$(aws sts get-caller-identity --query Account --output text)" = "$ACCOUNT_ID" ] \
  && echo "account OK: $ACCOUNT_ID ($AWS_REGION)" || echo "STOP: default profile is a different account"
for d in frontend/terraform backend/terraform IAC/terraform; do
  terraform -chdir=$d init -input=false >/dev/null && echo "init $d"
done
```

If the account differs, or a stack's `terraform.tfstate` is missing, stop
and tell the user. Don't delete resources by hand from guesses.

**Record what exists, before any state is destroyed.** The verification in
§11.7 needs these names after the outputs are gone. Keep an existing
`teardown-ids.sh`: a re-run after a partial teardown must not overwrite it
with empty values.

```bash
source deploy-artifacts/env.sh
source deploy-artifacts/teardown-lib.sh
for d in frontend/terraform backend/terraform IAC/terraform; do
  echo "## $d: $(state_count $d) resources"; terraform -chdir=$d state list 2>/dev/null
done > deploy-artifacts/teardown-inventory.txt
grep '^##' deploy-artifacts/teardown-inventory.txt

if [ ! -s deploy-artifacts/teardown-ids.sh ]; then
  out()  { terraform -chdir="$1" output -raw "$2" 2>/dev/null; }
  repo() { out "$1" ecr_repository_url | sed 's#.*/##'; }
  THUMBS_DOMAIN="$(out backend/terraform thumbnails_cdn_domain)"
  THUMBS_CDN_ID=""
  [ -n "$THUMBS_DOMAIN" ] && THUMBS_CDN_ID="$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?DomainName=='$THUMBS_DOMAIN'].Id | [0]" --output text)"
  DB_INSTANCE="$(tfvar backend/terraform backend_name)"
  {
    echo "# Captured by DEPLOY_AWS.md §11.1 before teardown. Do not edit."
    echo "export PROJECT_NAME=$(tfvar IAC/terraform project_name)"
    echo "export VPC_ID=$(out IAC/terraform vpc_id)"
    echo "export PIPELINE_CLUSTER=$(out IAC/terraform ecs_cluster)"
    echo "export TRANSCODER_REPO=$(repo IAC/terraform)"
    echo "export TRANSCODER_LOG_GROUP=/ecs/$(tfvar IAC/terraform ecs_task_family)"
    echo "export RAW_BUCKET=$(out IAC/terraform raw_bucket)"
    echo "export PROCESSED_BUCKET=$(out IAC/terraform processed_bucket)"
    echo "export QUEUE_URLS='$(out IAC/terraform ingest_queue_url) $(out IAC/terraform ingest_dlq_url) $(out IAC/terraform completion_queue_url) $(out IAC/terraform completion_dlq_url)'"
    echo "export LAMBDA_NAME=$(out IAC/terraform lambda_function_name)"
    echo "export USER_POOL_ID=$(out IAC/terraform cognito_user_pool_id)"
    echo "export REDIS_NAME=$(tfvar IAC/terraform redis_cache_name)"
    echo "export VIDEO_CDN_ID=$(out IAC/terraform cloudfront_distribution_id)"
    echo "export BACKEND_CLUSTER=$(out backend/terraform ecs_cluster)"
    echo "export BACKEND_REPO=$(repo backend/terraform)"
    echo "export BACKEND_LOG_GROUP=$(out backend/terraform log_group)"
    echo "export THUMBS_BUCKET=$(out backend/terraform thumbnails_bucket)"
    echo "export THUMBS_CDN_ID=${THUMBS_CDN_ID/None/}"
    echo "export DB_INSTANCE=$DB_INSTANCE"
    echo "export DB_FINAL_SNAPSHOT=$DB_INSTANCE-final"
    echo "export FRONTEND_REPO=$(repo frontend/terraform)"
    echo "export FRONTEND_LOG_GROUP=$(out frontend/terraform log_group)"
    echo "export FRONTEND_URL_WAS=$(out frontend/terraform frontend_url)"
  } > deploy-artifacts/teardown-ids.sh
fi
cat deploy-artifacts/teardown-ids.sh
```

**Checks that decide what to ask in §11.2:**

```bash
source deploy-artifacts/env.sh
source deploy-artifacts/teardown-ids.sh
# 1. A final snapshot from an earlier teardown blocks the RDS delete.
aws rds describe-db-snapshots --db-snapshot-identifier "$DB_FINAL_SNAPSHOT" \
  --query 'DBSnapshots[0].[DBSnapshotIdentifier,SnapshotCreateTime,Status]' --output text 2>/dev/null \
  || echo "no existing $DB_FINAL_SNAPSHOT snapshot"
# 2. Cognito deletion protection (INACTIVE unless someone changed it).
[ -n "$USER_POOL_ID" ] && aws cognito-idp describe-user-pool --user-pool-id "$USER_POOL_ID" \
  --query 'UserPool.DeletionProtection' --output text
# 3. Transcodes in flight (they would be cut off).
[ -n "$PIPELINE_CLUSTER" ] && aws ecs list-tasks --cluster "$PIPELINE_CLUSTER" \
  --desired-status RUNNING --query 'length(taskArns)' --output text
# 4. How much video data is about to be deleted.
for b in "$RAW_BUCKET" "$PROCESSED_BUCKET" "$THUMBS_BUCKET"; do
  [ -n "$b" ] && echo "$b: $(aws s3 ls "s3://$b" --recursive --summarize 2>/dev/null | grep -E 'Total (Objects|Size)' | tr '\n' ' ')"
done
```

### 11.2 Ask the user

Ask **once**, in a single message, and wait for an explicit yes. Show:

1. The account ID, the region, and the resource count per stack from
   `teardown-inventory.txt`.
2. The frontend URL that will stop working (`FRONTEND_URL_WAS`).
3. That **all videos, thumbnails and user accounts are deleted permanently**,
   with the object counts and sizes from check 4.
4. If check 3 found running transcoder tasks: say they will be stopped.
5. If check 2 says `ACTIVE`: say you will set Cognito deletion protection to
   `INACTIVE` first.
6. **The RDS snapshot.** Ask them to choose:
   - **Keep `video-backend-final`** (default). It allows a restore later and
     costs a small amount of snapshot storage each month.
   - **Delete it** after the teardown, so nothing is left.

   If check 1 found an existing snapshot, also ask them to choose:
   - **Rename it:** copy it to `video-backend-final-<its date>`, then delete
     the original.
   - **Delete it.**

   Either way, the new final snapshot can then be created.
7. Roughly 30–50 minutes.

If they decline, stop. Nothing has been changed yet.

Record the answers in `deploy-artifacts/deploy-log.md`. If check 1 found a
snapshot, deal with it now as the user chose:

```bash
source deploy-artifacts/env.sh
source deploy-artifacts/teardown-ids.sh
# Rename = copy + delete (skip the copy if the user chose delete):
OLD_DATE="$(aws rds describe-db-snapshots --db-snapshot-identifier "$DB_FINAL_SNAPSHOT" \
  --query 'DBSnapshots[0].SnapshotCreateTime' --output text | cut -c1-10)"
aws rds copy-db-snapshot --source-db-snapshot-identifier "$DB_FINAL_SNAPSHOT" \
  --target-db-snapshot-identifier "$DB_FINAL_SNAPSHOT-$OLD_DATE" --query 'DBSnapshot.Status'
aws rds wait db-snapshot-available --db-snapshot-identifier "$DB_FINAL_SNAPSHOT-$OLD_DATE"
# Then, for both choices:
aws rds delete-db-snapshot --db-snapshot-identifier "$DB_FINAL_SNAPSHOT" --query 'DBSnapshot.Status'
aws rds wait db-snapshot-deleted --db-snapshot-identifier "$DB_FINAL_SNAPSHOT"
```

### 11.3 Frontend stack

Skip this step if `state_count frontend/terraform` is `0`. Its ECR repo is
`force_delete`, so its images go with it.

```bash
source deploy-artifacts/env.sh
cd frontend/terraform
terraform plan -destroy -input=false -out=destroy.tfplan \
  | tee "$REPO_ROOT/deploy-artifacts/destroy-frontend.txt" | tail -3
```

The last line must say `0 to add, 0 to change, N to destroy`. Then run in
the background:

```bash
source deploy-artifacts/env.sh
cd frontend/terraform
terraform apply -input=false destroy.tfplan 2>&1 | tee -a "$REPO_ROOT/deploy-artifacts/destroy-frontend.txt" | tail -5
echo "left in state: $(terraform state list | wc -l)"     # 0
```

This takes about 5–10 minutes while Express Mode drains the service. The
shared ALB stays up, because the API still uses it.

### 11.4 Backend stack

Skip this step if `state_count backend/terraform` is `0`.

**Lift RDS deletion protection.** This is a targeted apply. The plan must
change only `aws_db_instance.main` in place (`0 to add, 1 to change, 0 to
destroy`), or show no changes if protection is already off. If it shows
anything else, stop and ask.

```bash
source deploy-artifacts/env.sh
source deploy-artifacts/teardown-ids.sh
cd backend/terraform
terraform plan -input=false -target=aws_db_instance.main -var db_deletion_protection=false \
  -out=unprotect.tfplan | tail -3
terraform apply -input=false unprotect.tfplan | tail -2
aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].DeletionProtection'                             # false
```

The `-target` warning Terraform prints is expected.

**Empty the backend's ECR repo, then plan the destroy:**

```bash
source deploy-artifacts/env.sh
source deploy-artifacts/teardown-ids.sh
source deploy-artifacts/teardown-lib.sh
empty_ecr "$BACKEND_REPO"
cd backend/terraform
terraform plan -destroy -input=false -var db_deletion_protection=false -out=destroy.tfplan \
  | tee "$REPO_ROOT/deploy-artifacts/destroy-backend.txt" | tail -3
```

Then apply it in the background. It takes 15–25 minutes:
- the thumbnails CloudFront distribution is disabled, then deleted;
- RDS writes `video-backend-final`, then deletes the instance;
- both ECS services drain.

```bash
source deploy-artifacts/env.sh
cd backend/terraform
terraform apply -input=false destroy.tfplan 2>&1 | tee -a "$REPO_ROOT/deploy-artifacts/destroy-backend.txt" | tail -5
echo "left in state: $(terraform state list | wc -l)"     # 0
```

### 11.5 Pipeline stack

Skip this step if `state_count IAC/terraform` is `0`.

**Stop in-flight transcodes.** A running task blocks deleting the cluster.
Also empty the transcoder repo, and wait until Express Mode has removed its
ALB from the VPC:

```bash
source deploy-artifacts/env.sh
source deploy-artifacts/teardown-ids.sh
source deploy-artifacts/teardown-lib.sh
for t in $(aws ecs list-tasks --cluster "$PIPELINE_CLUSTER" --desired-status RUNNING \
             --query 'taskArns[]' --output text 2>/dev/null); do
  aws ecs stop-task --cluster "$PIPELINE_CLUSTER" --task "$t" --reason teardown --query 'task.lastStatus'
done
empty_ecr "$TRANSCODER_REPO"
wait_vpc_clear "$VPC_ID" && echo "VPC clear" || echo "VPC NOT clear yet"
```

If it says `NOT clear`, run only `wait_vpc_clear` again (each run waits up
to 9 minutes). If a load balancer is still there 20 minutes after §11.4,
§11.10 says how to remove it.

**If check 2 in §11.1 was `ACTIVE`**, turn Cognito deletion protection off
first with a targeted apply. The plan must show only the user pool changing
in place:

```bash
source deploy-artifacts/env.sh
cd IAC/terraform
terraform plan -input=false -target=aws_cognito_user_pool.this \
  -var cognito_deletion_protection=INACTIVE -out=unprotect.tfplan | tail -3
terraform apply -input=false unprotect.tfplan | tail -2
```

**Destroy.** Plan it:

```bash
source deploy-artifacts/env.sh
cd IAC/terraform
terraform plan -destroy -input=false -out=destroy.tfplan \
  | tee "$REPO_ROOT/deploy-artifacts/destroy-pipeline.txt" | tail -3
```

Then apply it in the background. It takes 10–20 minutes:
- the playback CloudFront distribution;
- ElastiCache Serverless;
- the S3 buckets, which are emptied by `force_destroy`. This is slow when
  they hold many objects.

```bash
source deploy-artifacts/env.sh
cd IAC/terraform
terraform apply -input=false destroy.tfplan 2>&1 | tee -a "$REPO_ROOT/deploy-artifacts/destroy-pipeline.txt" | tail -5
echo "left in state: $(terraform state list | wc -l)"     # 0
```

### 11.6 Leftovers outside Terraform

ECS creates Container Insights log groups for both clusters, and Terraform
doesn't track them. Also remove any of the stacks' log groups that something
re-created after Terraform deleted them, such as a late Lambda invocation:

```bash
source deploy-artifacts/env.sh
source deploy-artifacts/teardown-ids.sh
for c in "$BACKEND_CLUSTER" "$PIPELINE_CLUSTER"; do
  [ -n "$c" ] || continue
  for g in $(aws logs describe-log-groups --log-group-name-prefix "/aws/ecs/containerinsights/$c/" \
               --query 'logGroups[].logGroupName' --output text); do
    aws logs delete-log-group --log-group-name "$g" && echo "deleted $g"
  done
done
for g in "$BACKEND_LOG_GROUP" "$FRONTEND_LOG_GROUP" "$TRANSCODER_LOG_GROUP" "/aws/lambda/$LAMBDA_NAME"; do
  aws logs delete-log-group --log-group-name "$g" 2>/dev/null && echo "deleted $g"
done
true
```

**If the user chose to delete the final snapshot:**

```bash
source deploy-artifacts/env.sh
source deploy-artifacts/teardown-ids.sh
aws rds wait db-snapshot-available --db-snapshot-identifier "$DB_FINAL_SNAPSHOT"
aws rds delete-db-snapshot --db-snapshot-identifier "$DB_FINAL_SNAPSHOT" --query 'DBSnapshot.Status'
```

### 11.7 Verify that nothing is left

Every line should read `gone` or `skip`. The only exceptions are the final
snapshot, if the user kept it, and the Terraform state counts, which must be
`0`.

```bash
source deploy-artifacts/env.sh
source deploy-artifacts/teardown-ids.sh
source deploy-artifacts/teardown-lib.sh
{
for d in frontend/terraform backend/terraform IAC/terraform; do
  echo "state    $d: $(state_count $d) resources"
done
echo "-- compute and networking"
none "ECS clusters (ACTIVE)" aws ecs describe-clusters --clusters "${BACKEND_CLUSTER:-none}" "${PIPELINE_CLUSTER:-none}" \
       --query "clusters[?status=='ACTIVE'].clusterName" --output text
gone "VPC"                   "$VPC_ID" aws ec2 describe-vpcs --vpc-ids "$VPC_ID"
none "load balancers in VPC" aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerName" --output text
none "target groups in VPC"  aws elbv2 describe-target-groups  --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupName" --output text
none "ECS autoscaling targets" aws application-autoscaling describe-scalable-targets --service-namespace ecs \
       --query "ScalableTargets[?contains(ResourceId,'/${BACKEND_CLUSTER:-none}/')].ResourceId" --output text
gone "Lambda"                "$LAMBDA_NAME" aws lambda get-function --function-name "$LAMBDA_NAME"
echo "-- data"
gone "RDS instance"          "$DB_INSTANCE" aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE"
gone "ElastiCache"           "$REDIS_NAME" aws elasticache describe-serverless-caches --serverless-cache-name "$REDIS_NAME"
for b in "$RAW_BUCKET" "$PROCESSED_BUCKET" "$THUMBS_BUCKET"; do
  gone "S3 $b" "$b" aws s3api head-bucket --bucket "$b"
done
for q in $QUEUE_URLS; do
  gone "SQS ${q##*/}" "$q" aws sqs get-queue-attributes --queue-url "$q" --attribute-names QueueArn
done
gone "Cognito user pool"     "$USER_POOL_ID" aws cognito-idp describe-user-pool --user-pool-id "$USER_POOL_ID"
gone "SSM client secret"     "$PROJECT_NAME" aws ssm get-parameter --name "/$PROJECT_NAME/cognito/client-secret"
echo "-- delivery and images"
gone "CloudFront playback"   "$VIDEO_CDN_ID"  aws cloudfront get-distribution --id "$VIDEO_CDN_ID"
gone "CloudFront thumbnails" "$THUMBS_CDN_ID" aws cloudfront get-distribution --id "$THUMBS_CDN_ID"
for r in "$FRONTEND_REPO" "$BACKEND_REPO" "$TRANSCODER_REPO"; do
  gone "ECR $r" "$r" aws ecr describe-repositories --repository-names "$r"
done
echo "-- logs"
for g in "$BACKEND_LOG_GROUP" "$FRONTEND_LOG_GROUP" "$TRANSCODER_LOG_GROUP" "/aws/lambda/$LAMBDA_NAME" \
         "/aws/ecs/containerinsights/$BACKEND_CLUSTER/" "/aws/ecs/containerinsights/$PIPELINE_CLUSTER/"; do
  none "log group $g" aws logs describe-log-groups --log-group-name-prefix "$g" --query 'logGroups[].logGroupName' --output text
done
echo "-- kept on purpose (if the user chose to keep it)"
gone "RDS snapshot $DB_FINAL_SNAPSHOT" "$DB_FINAL_SNAPSHOT" aws rds describe-db-snapshots --db-snapshot-identifier "$DB_FINAL_SNAPSHOT"
echo "-- anything else still tagged Project=$PROJECT_NAME (tag index can lag by minutes)"
for r in "$AWS_REGION" us-east-1; do
  none "tagged in $r" aws resourcegroupstaggingapi get-resources --region "$r" \
         --tag-filters "Key=Project,Values=$PROJECT_NAME" --query 'ResourceTagMappingList[].ResourceARN' --output text
done
} 2>&1 | tee deploy-artifacts/teardown-verify.txt
```

How to read the result:
- **`LEFT`:** a real leftover. Use §11.10, then run the verification again.
- **`CHECK`:** an error that wasn't "not found", usually `AccessDenied`.
  Report it as unverified; don't call it gone.
- **Tag-index entries:** if the matching resource checks above say `gone`,
  wait a few minutes and run the verification again before reporting them.
- **The kept snapshot** shows as `LEFT … RDS snapshot`. That is expected
  when the user chose to keep it.

### 11.8 Local clean-up

Leave these in place unless the user asks otherwise:
- The emptied `terraform.tfstate*` files and the `terraform.tfvars` files,
  so a redeploy reuses the same names.
- `deploy-artifacts/`. It has the logs, plans and verification output.
  `env.sh` keeps a redeploy on the same bucket names.

Remove only the plan files and the local copies of the pushed images:

```bash
source deploy-artifacts/env.sh
rm -f frontend/terraform/*.tfplan backend/terraform/*.tfplan IAC/terraform/*.tfplan \
      frontend/terraform/tfplan backend/terraform/tfplan IAC/terraform/tfplan
docker images --format '{{.Repository}}:{{.Tag}}' \
  | grep -E "^$ACCOUNT_ID\.dkr\.ecr\.$AWS_REGION\.amazonaws\.com/" \
  | xargs -r docker rmi >/dev/null && echo "local ECR images removed"
git status --short     # nothing new should be tracked
```

### 11.9 Report back to the user

Save this as `deploy-artifacts/teardown-summary.md` and show it:

```
Teardown: COMPLETE | INCOMPLETE
Region / account: <region> / <account>
Destroyed: frontend <n>, backend <n>, pipeline <n> Terraform resources
           (+ <k> Container Insights log groups)
Frontend URL <FRONTEND_URL_WAS> no longer resolves.
Verification: <n> gone, <n> LEFT, <n> CHECK  (deploy-artifacts/teardown-verify.txt)
Kept: RDS snapshot video-backend-final (delete with
      aws rds delete-db-snapshot --db-snapshot-identifier video-backend-final)
      | nothing
Still billing: nothing | <each LEFT item>
Redeploy: DEPLOY_AWS.md from §2 (deploy-artifacts/env.sh is kept)
```

Only report `COMPLETE` when every Terraform state is at `0` and nothing is
`LEFT` except the kept snapshot.

### 11.10 Teardown troubleshooting

| Symptom | Fix |
|---|---|
| `InvalidParameterCombination: Cannot delete protected DB Instance` | §11.4's targeted apply didn't run, or didn't apply. Re-run it, then re-plan the destroy |
| `DBSnapshotAlreadyExists` | §11.1 check 1 was skipped. Handle the old snapshot per §11.2, then `terraform apply` a fresh `plan -destroy` |
| `RepositoryNotEmptyException` | `empty_ecr <repo>`, then re-plan and apply the destroy |
| Deleting the ECS cluster fails with `ClusterContainsTasksException` or `...ServicesException` | Stop the tasks (§11.5). For the backend, check that `aws ecs list-services --cluster video-backend` is empty, then wait a minute |
| Subnet, security group or VPC `DependencyViolation` | Something still has an ENI in the VPC: `aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=$VPC_ID --query 'NetworkInterfaces[].[NetworkInterfaceId,Description,Status]' --output table`. ELB or ECS ENIs: wait (`wait_vpc_clear`). Then re-plan and apply the destroy |
| An Express Mode ALB is still in the VPC 20 minutes after both services are gone | Show it to the user, and ask before deleting it, because Terraform didn't create it. Get its ARN and tags with `aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$VPC_ID']"` (expect `AmazonECSManaged`). Then: `aws elbv2 delete-load-balancer --load-balancer-arn <arn>`, then its target groups (`aws elbv2 describe-target-groups --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn"` → `delete-target-group`), then, after `wait_vpc_clear`, its security group (`aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID`; leave the `default` group) |
| CloudFront delete times out or fails with `DistributionNotDisabled` | The disable is still propagating. Wait until `aws cloudfront get-distribution --id <id> --query Distribution.Status` is `Deployed`, then re-plan and apply the destroy |
| `Error acquiring the state lock` after a killed shell | Make sure no `terraform` process is still running (`pgrep -fl terraform`), then `terraform force-unlock <id>` in that stack |
| A destroy stopped half-way | Safe to repeat: re-run that stack's `plan -destroy` and apply. State only lists what's left. Don't move on to the next stack until this one is at `0` |
| A stack's state is empty but AWS still has its resources (state lost) | Stop. Show the user the §11.7 output and ask. Remove resources by hand only with their approval, one at a time |
