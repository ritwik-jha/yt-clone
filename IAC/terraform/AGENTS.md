# AGENTS.md — terraform

Provisions the full pipeline infra. Single `terraform apply` stands up
network, storage, queues, cache, DB, container platform, and dispatcher.

## Files

| File | Owns |
|---|---|
| `providers.tf` | AWS provider (region, default tags), `archive` provider, `aws_caller_identity`, `aws_availability_zones`, `locals` (account_id, region, image_uri) |
| `variables.tf` | Every knob. Two required inputs: `raw_bucket_name`, `processed_bucket_name`. Everything else defaulted. |
| `network.tf` | `aws_vpc`, N public subnets across N AZs, IGW, public RT + associations, `egress_only` SG (workloads), `redis` SG (6379 from egress SG only) |
| `storage.tf` | S3 raw + processed buckets (public-access blocked, force_destroy on), CORS on raw, SQS ingest queue + DLQ (redrive), SQS completion queue + DLQ, SQS→S3 send-message policy, `aws_s3_bucket_notification` filter `suffix=.mp4` |
| `redis.tf` | `aws_elasticache_serverless_cache` (engine=redis, v7), 5 GB / 5000 eCPU limits, in redis SG + module subnets, locals expose `redis_address` / `redis_port` / `redis_uri` |
| `dynamodb.tf` | `video-status` table (PK `video_id`, GSI `uploader-created-index`), `users` table (PK `cognito_sub`, GSI `email-index`). PAY_PER_REQUEST, PITR on. |
| `cognito.tf` | User pool (`username_attributes=["email"]`, required `email`/`name` schema) + confidential app client (secret, `USER_PASSWORD_AUTH`, `prevent_user_existence_errors`) |
| `ecr.tf` | Private ECR repo, scan-on-push, 10-image lifecycle |
| `iam.tf` | ECS task-execution role (managed policy), ECS task role (S3 R/W on the two buckets + SendMessage on completion queue), Lambda dispatcher role (SQS receive/delete on ingest, `ecs:RunTask` on task family `:*`, `iam:PassRole` scoped by `iam:PassedToService=ecs-tasks`) |
| `ecs.tf` | CW log group, cluster (containerInsights on), task definition with runtimePlatform, env carries Redis + completion queue coordinates |
| `lambda.tf` | `archive_file` bundles `../lambda/`, `aws_lambda_function` (python3.12, 256 MB, 30s), CW log group, `aws_lambda_event_source_mapping` on ingest queue (batch_size, batch_window, `ReportBatchItemFailures`) |
| `outputs.tf` | Every consumer input the backend / operator needs: bucket names, queue URLs+ARNs, redis endpoint, DDB table names, ECR URL, cluster name, task def ARN, lambda name, Cognito pool/client ids (client secret marked `sensitive`) |
| `terraform.tfvars.example` | Copy → `terraform.tfvars`, fill required values |

## Conventions

- **Network is provisioned in-module.** Do not add `vpc_id` /
  `subnet_ids` input vars. Directive from user; see repo memory.
- **All resource names are variable-driven.** No literal strings for
  bucket/queue/table names outside `variables.tf` defaults.
- **Provider version pinned** to `~> 5.60`. Bump deliberately.
- **`default_tags`** in `providers.tf` merges `{Project, ManagedBy=terraform}`
  with user `var.tags`. Do not add tags on individual resources unless
  they differ from defaults.
- **SG chaining, not CIDR.** Redis SG allows ingress only from the
  workload SG by ID. Never open Redis to `0.0.0.0/0`.
- **SQS visibility timeout ≥ 6× Lambda timeout** — AWS requirement for
  ESM. Defaults comply (180 vs 30).
- **`force_destroy = true`** on both S3 buckets so `terraform destroy`
  works cleanly in dev. Reconsider for prod.
- **Do NOT add** `fastapi_webhook_*` back — completion path is SQS now,
  not HTTP. If you re-add HTTP callback support, gate behind a flag; do
  not remove the SQS path.
- **Cognito username is email, not a separate field.** `backend/app/routers/auth.py`
  passes `Username=<email>` at signup, confirm, and login, so
  `username_attributes = ["email"]` on the pool is load-bearing — do not
  drop it or logins break.
- **`cognito_user_pool_client_secret` is a sensitive output**, which means
  it lands in this stack's state file like any other Terraform secret.
  `terraform output -json` still returns the real value (sensitivity only
  redacts human-readable output); that's how `backend/scripts/generate-env.sh`
  reads it. Keep state access as restricted as the `.env` file itself.

## Adding a new resource

1. Add variable(s) to `variables.tf` (typed, described, defaulted where
   possible).
2. Create/extend the appropriate `.tf` file; use `local.*` from
   `providers.tf` for account/region/image_uri.
3. Export via `outputs.tf` if any consumer (backend, external module,
   docs) needs the ARN/URL.
4. Update `terraform.tfvars.example` if the variable is required.
5. Update `deployment-guide.md` assumption table and — if the change
   affects a component — the corresponding component's `AGENTS.md`.

## Terraform commands

```
terraform init
terraform plan     # always review before apply
terraform apply
terraform destroy  # S3 force_destroy handles bucket contents; ECR may block — batch-delete-image first
```

Never run `terraform apply -auto-approve` in this dir without a fresh
`plan`. State changes here touch VPC, IAM, and a live SQS→Lambda pipeline.
