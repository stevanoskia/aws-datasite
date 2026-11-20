# 10-network: the project's network. Applied by the CI pipeline (infra workflow).

module "network" {
  source = "../../modules/network"

  name_prefix = var.project
  vpc_cidr    = var.vpc_cidr
}
