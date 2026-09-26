# Backend Deployment Guide

Written for: an engineer deploying this repo's backend to AWS for the first time.

Deploys the FastAPI API and the SQS completion poller as two Docker
containers on a single EC2 instance.

**This guide assumes the transcoding pipeline is already deployed.** Run
`IAC/deployment-guide.md` to completion first — every value the backend needs
(queue URL, table names, Redis endpoint, raw bucket) is read out of that
stack's Terraform state.

---

## 1. What gets created

`backend/terraform/` is a second, independent Terraform stack. It reads the
pipeline stack's outputs through `terraform_remote_state` and never modifies
pipeline resources.

| Resource | File |
|---|---|
| EC2 instance (Ubuntu, Docker, in the pipeline VPC) | `ec2.tf` |
| Elastic IP | `ec2.tf` |
| Instance role + profile (Cognito, DynamoDB, S3, SQS, SSM, ECR, logs) | `iam.tf` |
| Instance security group | `network.tf` |
| Ingress rule opening Redis 6379 to the instance SG | `network.tf` |
| ECR repository for the backend image | `ecr.tf` |
| S3 thumbnails bucket (+ CORS) | `storage.tf` |
| SSM SecureString parameter holding the `.env` | `ssm.tf` |
| CloudWatch log group `/video-backend` | `logs.tf` |

The Cognito user pool + app client this instance authenticates against is
provisioned by the **pipeline** stack (`IAC/terraform/cognito.tf`), not here —
this stack only reads its ARN via `terraform_remote_state` to scope the
instance's IAM policy. Still **not** created by any stack in this repo: any
**ALB / TLS certificate** in front of the instance.

---

## 2. How a deploy works

```
       workstation                          AWS                        instance
  ---------------------          --------------------------      --------------------
  push-image.sh        --build-->  ECR: video-backend:latest  <--pull--  docker compose
  generate-env.sh      --------->  SSM: /video-backend/env    <--get---  deploy.sh
  terraform apply      --------->  EC2 + IAM + SG + bucket    --------->  user_data
```

The instance holds no application state. `deploy.sh` runs on the box (via the
`video-backend` systemd unit), pulls the `.env` from SSM Parameter Store,
authenticates to ECR, and runs `docker compose up -d`. Redeploying is
`systemctl restart video-backend` — the instance is never rebuilt for a code
or config change.

Terraform seeds the SSM parameter with a placeholder and then ignores its
value, so `terraform apply` never has to hold `COGNITO_CLIENT_SECRET`.

---

## 3. Prerequisites

- Pipeline stack applied (`IAC/terraform`), state file reachable — this is
  also where the Cognito user pool + app client get created.
- Terraform ≥ 1.5, AWS CLI v2, Docker with `buildx`, `jq`.
- The Session Manager plugin for the AWS CLI, if you want a shell on the box
  without opening SSH.

---

## 4. Steps

### Step 1 — Configure the stack

```bash
cd backend/terraform
cp terraform.tfvars.example terraform.tfvars
```

One value is required and has no default:

| Variable | Value |
|---|---|
| `thumbnails_bucket_name` | a globally unique S3 bucket name |

Check `aws_region` matches the pipeline. A mismatch fails the plan with an
explicit error rather than silently pointing the instance at another region's
queues.

If the pipeline state is in S3 rather than on disk, set
`pipeline_state_backend = "s3"` plus `pipeline_state_s3_bucket` /
`pipeline_state_s3_key`.

### Step 2 — Apply

```bash
terraform init
terraform plan
terraform apply
```

Outputs to note: `ecr_repository_url`, `env_ssm_parameter`, `instance_id`,
`public_ip`, `thumbnails_bucket`.

The instance boots and starts the `video-backend` unit immediately. It will
fail and retry every 30 seconds until Steps 3 and 4 are done — that is
expected, not a fault.

### Step 3 — Build and push the image

```bash
cd ..                      # backend/
scripts/push-image.sh
```

The build platform must match `cpu_architecture` in `terraform.tfvars`. The
default pair is `t4g.small` + `arm64` + `linux/arm64`. For an Intel instance
set `cpu_architecture = "amd64"`, an `m*`/`t3` instance type, and run
`PLATFORM=linux/amd64 scripts/push-image.sh`.

### Step 4 — Generate and push the `.env`

`generate-env.sh` reads both Terraform states and fills in every
infrastructure value, Cognito included:

```bash
scripts/generate-env.sh --push-ssm
```

This writes `backend/.env` (mode 600, gitignored) and uploads it to the SSM
parameter. The script refuses to run if a required value — Cognito among
them — can't be read from the pipeline state.

Review the generated file before the push if you want to change anything the
script carries over rather than derives — `CORS_ORIGINS`, `COOKIE_SECURE`,
`COOKIE_SAMESITE`, and the poll/TTL tunables all come from your existing
`.env` (then the environment, then `.env.example`).

Reading a state file directly, with no `terraform` binary:

```bash
scripts/generate-env.sh --state ../IAC/terraform/terraform.tfstate
```

### Step 5 — Start the containers

```bash
aws ssm start-session --target "$(terraform -chdir=terraform output -raw instance_id)"

sudo systemctl restart video-backend
systemctl status video-backend
docker compose -f /opt/video-backend/docker-compose.yml ps
```

Both containers should be `running`, and `api` should reach `healthy` within
about 15 seconds.

### Step 6 — Verify

On the instance:

```bash
curl -fsS localhost:8000/healthz          # {"status":"ok"}
```

From your workstation, without opening a port:

```bash
aws ssm start-session \
  --target "$(terraform -chdir=terraform output -raw instance_id)" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8000"],"localPortNumber":["8000"]}'

curl -fsS localhost:8000/healthz
```

Logs, for both containers:

```bash
aws logs tail /video-backend --follow
```

End-to-end, once the pipeline smoke test from `IAC/deployment-guide.md` has
put a video through: `GET /videos/{video_id}/progress` should return a
percentage while the Fargate task runs, and the `video-status` row should
flip to `COMPLETED` within a few seconds of the transcoder finishing.

---

## 5. Exposing the API

The instance SG opens nothing inbound by default; Session Manager needs no
open port. Pick one:

- **ALB (recommended for anything real).** Create the ALB and an ACM
  certificate, then set `api_ingress_cidrs` to the ALB subnet CIDRs — or
  better, replace that rule with one referencing the ALB's security group,
  using `security_group_id` from this stack's outputs as the target.
- **Direct, for testing.** Set `api_ingress_cidrs = ["<your-ip>/32"]` and
  reach `http://<public_ip>:8000`. Set `COOKIE_SECURE=false` in `.env` first,
  or the login cookies will be dropped over plain HTTP.

The API runs uvicorn with `--proxy-headers --forwarded-allow-ips '*'`, so
behind a proxy it honors `X-Forwarded-Proto` when deciding to mark cookies
`Secure`. Only terminate TLS at a proxy you control — those flags trust the
forwarded headers unconditionally.

---

## 6. Routine operations

| Task | Command |
|---|---|
| Ship new code | `scripts/push-image.sh` then `sudo systemctl restart video-backend` |
| Change config | edit `.env`, `scripts/generate-env.sh --push-ssm`, restart the unit |
| Re-sync config after a pipeline apply | `scripts/generate-env.sh --push-ssm`, restart |
| Tail logs | `aws logs tail /video-backend --follow` |
| Restart one container | `docker compose -f /opt/video-backend/docker-compose.yml restart poller` |
| Stop everything | `sudo systemctl stop video-backend` |

`user_data_replace_on_change = true` means editing `docker-compose.yml`,
`scripts/deploy.sh`, or the systemd unit **replaces the instance** on the
next apply — those three files are baked into user_data. Review the plan.

---

## 7. Teardown

```bash
cd backend/terraform
terraform destroy
```

Destroy this stack before the pipeline stack: it holds an ingress rule on the
pipeline's Redis security group, and the pipeline's destroy will fail while
that rule exists. The thumbnails bucket has `force_destroy = true`; ECR does
not, so run `aws ecr batch-delete-image` if the repo blocks the destroy.

---

## 8. Gotchas

- **Image architecture.** `t4g.*` is arm64. An amd64 image on an arm64
  instance fails at `docker compose up` with `exec format error`.
- **Placeholder `.env`.** If `deploy.sh` reports the parameter still holds the
  Terraform placeholder, Step 4 has not run.
- **Redis reachability.** The instance must stay in the pipeline VPC. The
  ingress rule in `network.tf` is what opens 6379, and it is keyed on this
  stack's SG — moving the instance out of the VPC breaks the progress
  endpoint with a connect timeout.
- **`.env` is secret.** It carries `COGNITO_CLIENT_SECRET`. It is gitignored
  and written mode 600 both locally and on the instance; keep it that way.
- **Region drift.** `aws_region` must match the pipeline stack. The `check`
  block catches it at plan time.
- **Single instance, no autoscaling.** This is one EC2 box. The poller is a
  single consumer of the completion queue, which is fine — SQS redelivers on
  failure — but the API has no redundancy. Front it with an ASG + ALB before
  it matters.
