# Applied third, after IAC/terraform (VPC, subnets, processed bucket) and
# backend/terraform (ECS cluster, API URL, media key group). Reads both
# states. The one thing it changes outside its own resources is the
# processed bucket's policy (cloudfront.tf).
data "terraform_remote_state" "pipeline" {
  backend = "local"
  config  = { path = var.pipeline_state_local_path }
}

data "terraform_remote_state" "backend" {
  backend = "local"
  config  = { path = var.backend_state_local_path }
}
