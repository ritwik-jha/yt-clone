# AGENTS.md — backend/terraform

The ECS stack the backend runs on: the API as an ECS Express Mode service
(Express Mode creates its HTTPS ALB) and the completion poller as a plain
Fargate service. Applied **after** `../../IAC/terraform`, as a separate state.

## Files

| File | Owns |
|---|---|
| `providers.tf` | AWS provider (`~> 6.23`), `default_tags`, `locals` (account, region, `pipeline`, `backend_image`), `check` asserting the region matches the pipeline |
| `variables.tf` | Every knob. One required input: `thumbnails_bucket_name`. |
| `data.tf` | `terraform_remote_state.pipeline` (local or s3) |
| `network.tf` | API SG (container port from the VPC CIDR) and poller SG (egress only) in the pipeline VPC, and the rule adding the API SG as a source on the pipeline's Redis SG |
| `iam.tf` | Per-service execution and task roles for the API and poller, plus the Express Mode infrastructure role |
| `ecs.tf` | Cluster, per-service environment maps, `aws_ecs_express_gateway_service.api`, poller task definition + `aws_ecs_service.poller` |
| `storage.tf` | Thumbnails S3 bucket (public access blocked, SSE, CORS for presigned PUT) |
| `logs.tf` | CloudWatch log group `/<backend_name>` with `api/` and `poller/` stream prefixes |
| `ecr.tf` | Backend image repo, scan-on-push, 10-image lifecycle |
| `outputs.tf` | `api_url`, `ecs_cluster`, `api_service_name`, `api_service_arn`, `poller_service_name`, `api_security_group_id`, `ecr_repository_url`, `backend_image`, `thumbnails_bucket`, `log_group` |

## Conventions

- **This stack never declares pipeline resources.** VPC, subnets, buckets,
  queues, tables, Redis, Cognito, the Cognito secret parameter, and the
  CloudFront domain all come from `local.pipeline`
  (`data.terraform_remote_state.pipeline.outputs`). If you need a new
  coordinate, add an output to `../../IAC/terraform/outputs.tf`. Don't rebuild
  the value from name fragments.
- **Task environment is built here, not from `.env`.** `local.api_environment`
  and `local.poller_environment` in `ecs.tf` are the production config. A new
  app setting goes into the map for each process that reads it.
- **Terraform never holds a secret in this stack.** `COGNITO_CLIENT_SECRET`
  reaches the API container through the `secret` block, as an ARN reference to
  the pipeline's SSM SecureString. Only the API execution role can read it.
- **One role pair per service.** The API task role has no SQS access and no
  `UpdateItem`. The poller task role has no Cognito, S3, or secret access.
  Grant new permissions to the one role that needs them.
- **Express Mode owns the API's load balancing.** The ALB, listener, target
  group, cert, autoscaling policy, and Express-managed SGs are not Terraform
  resources here. Change them through `aws_ecs_express_gateway_service.api`
  arguments. Changing `infrastructure_role_arn` forces replacement.
- **x86_64 only.** The provider has no architecture argument for Express
  Mode, so the API runs x86_64. The poller is pinned to `X86_64` so one
  `linux/amd64` image serves both.
- **Public subnets, no NAT.** Tasks get public IPs to reach ECR and AWS APIs.
  The poller SG allows no inbound traffic. The API SG allows only the
  container port from the VPC CIDR, which is how the Express Mode ALB reaches
  the tasks: the infrastructure role can only edit SGs tagged
  `AmazonECSManaged=true`, so it can't add that rule itself. Don't narrow
  it to a public CIDR or widen it to `0.0.0.0/0`.
- **`terraform apply` deploys code** when `image_tag` changes. Use a new tag
  per deploy. Re-pushing the same tag produces no diff.

## Adding a resource

1. Variable in `variables.tf` (typed, described, defaulted where possible).
2. Resource in the concern-matching `.tf` file; use `local.pipeline.*` for
   anything the pipeline owns.
3. Scoped statement in `iam.tf`, on the task role of the service that uses it.
4. Output it if an operator needs it.
5. Update `terraform.tfvars.example` if required, and
   `../deployment-guide.md` §1.

## Commands

```
terraform init -upgrade
terraform apply -target=aws_ecr_repository.backend   # first deploy only, before pushing
terraform plan  -var image_tag=<tag>
terraform apply -var image_tag=<tag>
terraform destroy       # BEFORE the pipeline stack — this stack holds an
                        # ingress rule on the pipeline's Redis SG
```
