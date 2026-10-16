# Applied third, after IAC/terraform (VPC, subnets) and backend/terraform
# (ECS cluster, API URL). Reads both states; modifies neither.
data "terraform_remote_state" "pipeline" {
  backend = "local"
  config  = { path = var.pipeline_state_local_path }
}

data "terraform_remote_state" "backend" {
  backend = "local"
  config  = { path = var.backend_state_local_path }
}
