# 10-network: the project's network and the private access path. Applied by the CI pipeline.
#
#   module.network   VPC, 3 subnet tiers × 2 AZs, route tables, S3 endpoint, flow logs
#   module.nat       NAT instance in a public subnet
#   aws_route        app tier → internet via the NAT instance (connects the two modules)
#   module.operator  your daily access role: SSM sessions only from the allowed IPs
#   test instance    temporary, for the isolation proofs (test-instance.tf)

data "aws_caller_identity" "current" {}

# The boundary is created by 00-bootstrap; every role this stack creates must carry it
data "aws_iam_policy" "boundary" {
  name = "${var.project}-boundary"
}

module "network" {
  source = "../../modules/network"

  name_prefix = var.project
  vpc_cidr    = var.vpc_cidr
}

module "nat" {
  source = "../../modules/nat-instance"

  name_prefix              = var.project
  vpc_id                   = module.network.vpc_id
  subnet_id                = module.network.public_subnet_ids[0]
  client_cidrs             = module.network.app_subnet_cidrs
  permissions_boundary_arn = data.aws_iam_policy.boundary.arn
}

# The only way out of the app tier. The db tier gets no such route: it can't reach the internet at all.
resource "aws_route" "app_to_nat" {
  route_table_id         = module.network.app_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = module.nat.network_interface_id
}

module "operator" {
  source = "../../modules/operator-access"

  name_prefix              = var.project
  project_tag              = var.project
  allowed_source_cidrs     = var.operator_allowed_cidrs
  trusted_role_arns        = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.operator_trusted_role_path_name}"]
  permissions_boundary_arn = data.aws_iam_policy.boundary.arn
}
