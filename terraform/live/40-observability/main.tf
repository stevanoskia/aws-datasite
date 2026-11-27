# 40-observability: the monitoring server and the collector on the app server. Applied by the CI pipeline.
#
#   data.network    reads the outputs of 10-network (subnet, app security group)
#   data.app        reads the outputs of 30-app (the app server)
#   module.obs      monitoring server (Prometheus, Grafana) and the app server's collector (Alloy)
#   module.schedule weekdays 07:00-19:00 only, like the app server

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "10-network/terraform.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "app" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "30-app/terraform.tfstate"
    region = var.region
  }
}

# The boundary is created by 00-bootstrap; every role this stack creates must carry it
data "aws_iam_policy" "boundary" {
  name = "${var.project}-boundary"
}

module "obs" {
  source = "../../modules/observability"

  name_prefix              = var.project
  document_prefix          = "datasite" # SSM document names that start with "aws" are reserved
  vpc_id                   = data.terraform_remote_state.network.outputs.vpc_id
  subnet_id                = data.terraform_remote_state.network.outputs.app_subnet_ids[var.instance_az_index]
  app_security_group_id    = data.terraform_remote_state.network.outputs.app_security_group_id
  app_instance_id          = data.terraform_remote_state.app.outputs.app_instance_id
  permissions_boundary_arn = data.aws_iam_policy.boundary.arn
}

module "schedule" {
  source = "../../modules/scheduler"

  name_prefix              = var.project
  name                     = "obs"
  instance_ids             = [module.obs.instance_id]
  permissions_boundary_arn = data.aws_iam_policy.boundary.arn
}
