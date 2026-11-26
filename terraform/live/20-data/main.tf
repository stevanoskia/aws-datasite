# 20-data: the database. Applied by the CI pipeline.
#
#   data.network       reads the outputs of 10-network (VPC, db subnets, app security group)
#   module.postgres    private RDS PostgreSQL, reachable from the app server only
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

data "aws_subnet" "db" {
  id = data.terraform_remote_state.network.outputs.db_subnet_ids[var.instance_az_index]
}

module "postgres" {
  source = "../../modules/rds-postgres"

  name_prefix              = var.project
  vpc_id                   = data.terraform_remote_state.network.outputs.vpc_id
  subnet_ids               = data.terraform_remote_state.network.outputs.db_subnet_ids
  availability_zone        = data.aws_subnet.db.availability_zone
  client_security_group_id = data.terraform_remote_state.network.outputs.app_security_group_id
}

module "schedule" {
  source = "../../modules/scheduler"

  name_prefix              = var.project
  name                     = "db"
  db_instance_id           = module.postgres.instance_id
  permissions_boundary_arn = data.aws_iam_policy.boundary.arn
}

# The address for the app server, which reads it when it starts a version. A parameter's value is hidden in
# Terraform's output, so the internal name doesn't reach the public pipeline log.
resource "aws_ssm_parameter" "db_address" {
  name        = "/datasite/db/address" # names that start with "aws" are reserved by AWS
  description = "Private address of the database"
  type        = "String"
  value       = module.postgres.address
}
