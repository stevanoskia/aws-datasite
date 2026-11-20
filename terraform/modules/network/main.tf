# The project's own VPC. Phase 1 adds subnets, route tables, the NAT instance and flow logs here.

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true # the AWS resolver works inside the VPC
  enable_dns_hostnames = true # instances get DNS names (needed by SSM and VPC endpoints)

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# Every VPC comes with a "default" security group that allows all traffic between its members
# and all outbound traffic. Terraform takes it over and leaves it with NO rules, so nothing can
# use it by accident: every resource must get its own, explicit security group.
resource "aws_default_security_group" "locked" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-default-sg-locked"
  }
}
