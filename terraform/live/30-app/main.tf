# 30-app: the app server. Applied by the CI pipeline.
#
#   data.network       reads the outputs of 10-network (subnet, security group)
#   module.app_host    private server with Docker
#   module.db_secret   the app's database password, readable by this server only
#   module.migrate_secret  the migration login's password, readable by this server only
#   module.deploy      image registry and the fixed deploy and migrate scripts (ADR-0008)
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

# Filled by db/set_app_password.py --role shop_migrate
module "migrate_secret" {
  source = "../../modules/app-secret"

  name_prefix      = var.project
  name             = "migrate-db"
  description      = "Migration login (owns the tables), set by db/set_app_password.py"
  reader_role_name = module.app_host.role_name
  reader_role_arn  = module.app_host.role_arn
}

module "deploy" {
  source = "../../modules/app-deploy"

  name_prefix          = var.project
  host_role_name       = module.app_host.role_name
  db_address_parameter = "/${var.project}/db/address" # made by 20-data
  app_secret_name      = module.db_secret.name
  migrate_secret_name  = module.migrate_secret.name
}

module "schedule" {
  source = "../../modules/scheduler"

  name_prefix              = var.project
  name                     = "app"
  instance_ids             = [module.app_host.instance_id]
  permissions_boundary_arn = data.aws_iam_policy.boundary.arn
}
