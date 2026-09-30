# Backend Deployment Guide

Deploys the FastAPI API and the SQS completion poller as two ECS Fargate
services built from one image:

| Service | ECS flavour | Fronted by |
|---|---|---|
| `video-backend-api` | ECS Express Mode service | Internet-facing HTTPS ALB, created and managed by Express Mode |
| `video-backend-poller` | Standard ECS service | Nothing — it only makes outbound calls |

**This guide assumes the transcoding pipeline is already deployed.** Run
`IAC/deployment-guide.md` to completion first — every pipeline value the
backend needs (queue URL, Redis endpoint, raw bucket, CloudFront domain,
Cognito, VPC and subnets) is read out of that stack's Terraform state. The
database is this stack's own RDS PostgreSQL instance.

---

## 1. What gets created

`backend/terraform/` is a second, independent Terraform stack. It reads the
pipeline stack's outputs through `terraform_remote_state` and never modifies
pipeline resources, apart from adding one ingress rule to the Redis SG.

| Resource | File |
|---|---|
| ECS cluster `video-backend` | `ecs.tf` |
| API: `aws_ecs_express_gateway_service` (ALB, target group, listener rule, cert, autoscaling, SGs all managed by ECS) | `ecs.tf` |
| Poller: task definition + `aws_ecs_service` | `ecs.tf` |
| RDS PostgreSQL instance (`users`, `videos`) + subnet group; its master password is an RDS-managed Secrets Manager secret | `database.tf` |
| Five IAM roles: API execution, API task, poller execution, poller task, Express Mode infrastructure | `iam.tf` |
| API security group (container port from the VPC CIDR) and poller security group (egress only) | `network.tf` |
| Database security group (5432 from the API and poller SGs only) | `network.tf` |
| Ingress rule opening Redis 6379 to the API SG | `network.tf` |
| ECR repository for the backend image | `ecr.tf` |
| S3 thumbnails bucket (+ CORS) | `storage.tf` |
| CloudFront distribution + OAC for the thumbnails bucket | `cloudfront.tf` |
| CloudWatch log group `/video-backend` | `logs.tf` |

Created by the **pipeline** stack and only referenced here: the Cognito user
pool and app client, the SSM SecureString holding the Cognito client secret,
and the CloudFront distribution in front of the processed bucket.

### Roles

| Role | Assumed by | Can do |
|---|---|---|
| `video-backend-api-execution` | ECS agent, API tasks | Pull the backend image, write logs, read the Cognito secret parameter |
| `video-backend-api-task` | API code | Read the database secret, Cognito `AdminDeleteUser` (rolls back a signup whose `users` insert failed), `s3:PutObject` for presigned uploads |
| `video-backend-poller-execution` | ECS agent, poller tasks | Pull the backend image, write logs |
| `video-backend-poller-task` | Poller code | Read the database secret, drain the completion queue |
| `video-backend-express-infrastructure` | ECS Express Mode | Manage the API's ALB, target group, SGs, ACM cert, autoscaling (`AmazonECSInfrastructureRoleforExpressGatewayServices`) |

The poller can't read the Cognito secret. The other Cognito calls the API
makes (sign-up, login, refresh, revoke, `GetUser`) are public APIs that IAM
doesn't evaluate. Both services connect to PostgreSQL as the same master
user, so the rule that only the poller writes processing status is enforced
in code, not by the database.

---

## 2. How configuration reaches the containers

There is no `.env` in production. `ecs.tf` builds each service's environment
from the two stacks' state:

- non-secret values (database host and name, bucket names, Redis host,
  CloudFront domains, cookie and CORS policy) are plain task environment
  variables;
- `COGNITO_CLIENT_SECRET` is injected at task start from the pipeline's SSM
  SecureString, by the API execution role;
- the database password is never in the environment. Both services get
  `DB_SECRET_ARN` and read the RDS-managed secret themselves when they open a
  connection, so a rotation needs no redeploy.

Each process checks its own required settings at startup (`Settings.require`
in `app/config.py`), so the poller runs without any Cognito values.

`scripts/generate-env.sh` still writes `backend/.env`, but only for running
the code locally against the deployed resources.

---

## 3. Prerequisites

- Pipeline stack applied (`IAC/terraform`) with the CloudFront and Cognito
  secret-parameter changes, and its state file reachable.
- Terraform ≥ 1.5 with AWS provider 6.x (the stack pins `~> 6.23`), AWS CLI
  v2, Docker with `buildx`, `jq`.
- The operator IAM identity needs, beyond the usual ECS/IAM/EC2 rights, the
  ECS Express Mode service actions and `iam:PassRole` on the five roles
  above, plus RDS, Secrets Manager (RDS creates the master secret on your
  behalf), and CloudFront. Express Mode also creates ELB, ACM, and
  Application Auto Scaling resources through the infrastructure role.

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

Set `cors_origins` to your frontend origin(s). Check `aws_region` matches
the pipeline — a mismatch fails the plan.

The database defaults to a single-AZ `db.t4g.micro` with 20 GB of gp3
storage (autoscaling to 100 GB), 7 days of backups, and deletion protection
on. The `db_*` variables change that; `db_multi_az = true` is the main one
for production. If you raise `api_max_tasks` or `api_db_pool_size`, keep
2 × (`api_db_pool_size` + `api_db_max_overflow`) × `api_max_tasks` + 1
under the instance class's connection limit (roughly 80 on `db.t4g.micro`).

If the pipeline state is in S3 rather than on disk, set
`pipeline_state_backend = "s3"` plus `pipeline_state_s3_bucket` /
`pipeline_state_s3_key`.

### Step 2 — Create the ECR repository

The services can't start until an image exists, so create the repository
before anything else:

```bash
terraform init -upgrade
terraform apply -target=aws_ecr_repository.backend -target=aws_ecr_lifecycle_policy.backend
```

`-upgrade` is needed once if this directory was previously initialised with
the 5.x provider.

### Step 3 — Build and push the image

```bash
cd ..                      # backend/
scripts/push-image.sh "$(git rev-parse --short HEAD)"
```

The image is built for `linux/amd64`. The Terraform provider has no
architecture setting for Express Mode services, so the API runs x86_64. The
poller is pinned to x86_64 as well so both services can share one image.

### Step 4 — Apply everything

```bash
cd terraform
terraform plan  -var image_tag=<tag from step 3>
terraform apply -var image_tag=<tag from step 3>
```

Or set `image_tag` in `terraform.tfvars`. The API resource sets
`wait_for_steady_state = true`, so the apply only finishes once the API
tasks pass their ALB health check on `/healthz`. Creating the RDS instance
and the thumbnails distribution, and, for the first Express Mode service in
a VPC, the shared ALB and its certificate, takes a while, so expect 10–20
minutes on the first apply.

Each API task runs `alembic upgrade head` before starting uvicorn, so the
schema is created by the first task and upgraded on every deploy. The
migration holds a PostgreSQL advisory lock, so concurrent tasks don't race.
A failed migration stops the task before it serves traffic; its error is in
the API log stream.

Outputs to note: `api_url`, `ecs_cluster`, `api_service_name`,
`poller_service_name`, `ecr_repository_url`, `thumbnails_bucket`,
`thumbnails_cdn_domain`, `db_endpoint`, `db_secret_arn`.

### Step 5 — Verify

```bash
curl -fsS "$(terraform output -raw api_url)/healthz"     # {"status":"ok"}

aws ecs describe-services \
  --cluster "$(terraform output -raw ecs_cluster)" \
  --services "$(terraform output -raw poller_service_name)" \
  --query 'services[0].{running:runningCount,desired:desiredCount}'

aws logs tail /video-backend --follow     # streams api/... and poller/...
```

End to end, through the API (an upload made directly to S3, as in the
pipeline smoke test, has no `videos` row and never shows up here):

1. `POST /auth/signup`, `POST /auth/verify-otp` with the emailed code, then
   `POST /auth/login`, which sets the cookies.
2. `GET /upload/video/url` and `GET /upload/video/url/thumbnail`, then `PUT`
   the MP4 (`Content-Type: video/mp4`) and the JPEG
   (`Content-Type: image/jpeg`) to the returned URLs.
3. `POST /upload/video/save` with the returned `video_id` as `s3_key` and
   `thumbnail_id` as `thumbnail_s3_key`. The row starts as `PENDING`.
4. `GET /video/{id}/progress` moves to `PROCESSING` with a rising percentage
   while the Fargate transcoder runs, then reports `COMPLETED` and 100.
5. `GET /video/{id}` returns `manifest_url`
   (`https://dxxxx.cloudfront.net/<uuid from s3_key>/dash/manifest.mpd`),
   `thumbnail_url`, and `duration_seconds`. A PUBLIC video also appears in
   `GET /video/feed`.

Point a DASH player (dash.js, Shaka) at `manifest_url`. CloudFront serves
the manifest and segments from the private bucket via OAC, with CORS headers
added at the edge. Thumbnails come from this stack's own distribution the
same way.

If a video stays `PENDING`, check the poller log stream: `no row yet`
means the completion message beat the save and will redeliver, and a
message that never finds its row ends up in the completion DLQ.

---

## 5. Migrating from the EC2 deployment

If this stack was previously applied with the EC2 layout, Step 4's plan
**destroys** the instance, its Elastic IP, instance profile, instance SG,
the `/video-backend/env` SSM parameter, and the old Redis ingress rule.
Nothing on the instance is stateful, so this is safe. Review the plan
before applying.

---

## 6. Routine operations

| Task | Command |
|---|---|
| Ship new code | `scripts/push-image.sh <tag>` then `terraform apply -var image_tag=<tag>` |
| Change config | edit `terraform.tfvars` (or the pipeline), `terraform apply` |
| Re-sync after a pipeline apply | `terraform apply` here |
| Tail logs | `aws logs tail /video-backend --follow` |
| Restart the poller | `aws ecs update-service --cluster video-backend --service video-backend-poller --force-new-deployment` |
| Add a schema change | `alembic revision -m "<change>"` in `backend/`, edit it and `app/models.py`, then ship new code (the API applies it on start) |
| Stop the poller | `terraform apply -var poller_desired_count=0` |

Use a new image tag per deploy. Re-pushing `latest` doesn't change the task
definition, so Terraform sees no diff and nothing restarts.

---

## 7. Teardown

The RDS instance has deletion protection on by default, so turn it off
first:

```bash
cd backend/terraform
terraform apply -var db_deletion_protection=false
terraform destroy -var db_deletion_protection=false
```

The destroy takes a final snapshot named `<backend_name>-final`
(`video-backend-final`) and keeps it. That snapshot holds all users and
videos. Delete it with `aws rds delete-db-snapshot` once you no longer need
it; a later destroy of a recreated instance fails while a snapshot with that
name exists. The RDS-managed secret is deleted with the instance.

Destroy this stack before the pipeline stack: it holds an ingress rule on the
pipeline's Redis security group, and the pipeline's destroy will fail while
that rule exists. Express Mode deletes the ALB, target group, cert, and SGs
it created. The thumbnails bucket has `force_destroy = true`; ECR does not,
so run `aws ecr batch-delete-image` if the repo blocks the destroy.

---

## 8. Gotchas

- **Image architecture.** An arm64 image fails with `exec format error`.
  Keep `push-image.sh` on `linux/amd64` until the provider exposes Express
  Mode's architecture setting.
- **Public subnets, public task IPs.** The pipeline VPC has no NAT gateway.
  Tasks reach ECR and AWS APIs through public IPs: Express Mode assigns them
  automatically in public subnets, and the poller sets
  `assign_public_ip = true`. Nothing is reachable inbound except the API
  through its ALB.
- **Express Mode owns its networking.** Don't hand-edit the ALB or the SGs
  Express Mode creates. Its infrastructure role can only add rules to SGs it
  created (tagged `AmazonECSManaged=true`), so it can't open this stack's API
  SG to the ALB. `network.tf` admits the container port from the VPC CIDR
  for that reason. If `api_port` changes, that rule follows it.
- **Infrastructure role is immutable.** Changing
  `infrastructure_role_arn` replaces the API service.
- **Redis reachability.** Only the API SG is allowed on 6379. ElastiCache
  has no public endpoint, so Redis can't be reached from a workstation
  whatever the SG rules say. Debug from inside the VPC.
- **Database reachability.** The instance sits in the pipeline's public
  subnets (there are no private ones) but has `publicly_accessible = false`,
  so it has no public address, and its SG admits 5432 only from the API and
  poller SGs. To run `psql`, go through an API task with ECS Exec (not
  enabled by default) or run a one-off task in the API SG.
- **Redis is optional to the API.** Redis calls time out after 1 second and
  aren't retried. With Redis down, progress reads return 0 and
  `GET /video/{id}` reads PostgreSQL directly.
- **Single poller.** `poller_desired_count = 1` is intentional. More
  replicas are safe (the guarded UPDATEs are idempotent) but unnecessary.
