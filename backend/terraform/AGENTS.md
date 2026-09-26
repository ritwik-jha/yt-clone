# AGENTS.md — backend/terraform

The EC2 stack the backend containers run on. Applied **after**
`../../IAC/terraform`, as a separate state.

## Files

| File | Owns |
|---|---|
| `providers.tf` | AWS provider, `default_tags`, `locals` (account, region, `pipeline`, `backend_image`), `check` asserting the region matches the pipeline |
| `variables.tf` | Every knob. One required input: `thumbnails_bucket_name`. (Cognito needs no input — its ARN comes from `local.pipeline`.) |
| `data.tf` | `terraform_remote_state.pipeline` (local or s3), Canonical's public SSM parameter for the Ubuntu AMI id |
| `network.tf` | Instance SG in the pipeline VPC, opt-in API/SSH ingress, and the rule adding this SG as a source on the pipeline's Redis SG |
| `iam.tf` | Instance role + profile: Cognito (scoped to `local.pipeline.cognito_user_pool_arn`), DynamoDB, S3 presign authority, SQS completion queue, SSM/KMS for the env parameter, ECR pull, CloudWatch logs, `AmazonSSMManagedInstanceCore` |
| `storage.tf` | Thumbnails S3 bucket (public access blocked, SSE, CORS for presigned PUT) |
| `ssm.tf` | SecureString parameter `/<backend_name>/env`, placeholder value, `ignore_changes = [value]` |
| `logs.tf` | CloudWatch log group `/<backend_name>` for both container streams |
| `ecr.tf` | Backend image repo, scan-on-push, 10-image lifecycle |
| `ec2.tf` | Instance (IMDSv2, encrypted gp3, user_data from the template), optional EIP, arch/instance-type precondition |
| `user-data.sh.tftpl` | Bootstrap: Docker CE + compose plugin, AWS CLI v2, drop compose/deploy/unit, start the unit |
| `outputs.tf` | `instance_id`, `public_ip`, `security_group_id`, `ecr_repository_url`, `backend_image`, `env_ssm_parameter`, `thumbnails_bucket`, `log_group` |

## Conventions

- **This stack never declares pipeline resources.** VPC, subnets, buckets,
  queues, tables, Redis, and the Cognito pool all come from `local.pipeline`
  (`data.terraform_remote_state.pipeline.outputs`). If you need a new
  coordinate, add an output to `../../IAC/terraform/outputs.tf` — do not
  rebuild the value from name fragments.
- **Terraform never holds a secret.** `aws_ssm_parameter.backend_env` is
  created with a placeholder and `ignore_changes = [value]`.
  `../scripts/generate-env.sh --push-ssm` writes the real contents.
- **`terraform apply` does not deploy code.** It provisions. Shipping code is
  `push-image.sh` + `systemctl restart video-backend`.
- **Three files are baked into user_data** via `base64encode(file(...))`:
  `../docker-compose.yml`, `../scripts/deploy.sh`,
  `../systemd/video-backend.service`. With
  `user_data_replace_on_change = true`, editing any of them **replaces the
  instance**. Keep application logic out of them and in the image.
- **user_data is capped at 16 KB** before encoding; the three embedded files
  currently render to about 9.5 KB. Adding more will hit the ceiling — fetch
  from S3 or SSM instead.
- **`$${VAR}` in the template, not `$$(cmd)`.** `templatefile` only treats
  `${...}` as an interpolation, so brace-form shell expansions in
  `user-data.sh.tftpl` must be escaped as `$${VAR}`. `$(cmd)` and `$VAR`
  need no escaping — writing `$$(cmd)` there leaves a literal `$$` in the
  rendered script, which bash reads as the PID.
- **Architecture is paired.** `cpu_architecture` drives the AMI; a
  precondition on the instance rejects an `arm64`/`t3.*` style mismatch at
  plan time. The image built by `push-image.sh` must match too.
- **Ingress is opt-in.** `api_ingress_cidrs` and `ssh_ingress_cidrs` default
  to empty; access is Session Manager. Don't add a default-open rule.
- Provider pinned `~> 5.60`, matching the pipeline stack.

## Adding a resource

1. Variable in `variables.tf` (typed, described, defaulted where possible).
2. Resource in the concern-matching `.tf` file; use `local.pipeline.*` for
   anything the pipeline owns.
3. Scoped statement in `iam.tf` if the instance must reach it.
4. Output it if `generate-env.sh` or an operator needs it.
5. Update `terraform.tfvars.example` if required, and
   `../deployment-guide.md` §1.

## Commands

```
terraform init
terraform plan          # always; user_data changes can mean instance replacement
terraform apply
terraform destroy       # BEFORE the pipeline stack — this stack holds an
                        # ingress rule on the pipeline's Redis SG
```
