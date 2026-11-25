# 30-app: the app server. Applied by the CI pipeline.
#
#   data.network       reads the outputs of 10-network (subnet, security group)
#   module.app_host    private server with Docker
#   module.db_secret   the app's database password, readable by this server only
#   module.schedule    weekdays 07:00-19:00 only

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "10-network/terraform.tfstate"
    region = var.region
  }
}

# The boundary is created by 00-bootstrap; every role this stack creates must carry it
data "aws_iam_policy" "boundary" {
  name = "${var.project}-boundary"
}

module "app_host" {
  source = "../../modules/docker-host"

  name_prefix              = var.project
  name                     = "app"
  subnet_id                = data.terraform_remote_state.network.outputs.app_subnet_ids[var.instance_az_index]
  security_group_id        = data.terraform_remote_state.network.outputs.app_security_group_id
  permissions_boundary_arn = data.aws_iam_policy.boundary.arn
}

# Filled by db/set_app_password.py
module "db_secret" {
  source = "../../modules/app-secret"

  name_prefix      = var.project
  name             = "app-db"
  description      = "Database login of the app, set by db/set_app_password.py"
  reader_role_name = module.app_host.role_name
  reader_role_arn  = module.app_host.role_arn
}

module "schedule" {
  source = "../../modules/scheduler"

  name_prefix              = var.project
  name                     = "app"
  instance_ids             = [module.app_host.instance_id]
  permissions_boundary_arn = data.aws_iam_policy.boundary.arn
}
