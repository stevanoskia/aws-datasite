# Offline tests: the AWS provider is mocked, so nothing is created and no login is needed.
# Run with:  terraform init -backend=false ; terraform test   (or scripts/check.ps1 for everything)

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-north-1a", "eu-north-1b", "eu-north-1c"] }
  }
  mock_data "aws_region" {
    defaults = { region = "eu-north-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-bucket" }
  }
}

mock_provider "random" {}

variables {
  name_prefix = "test"
}

run "db_tier_has_no_way_out" {
  assert {
    condition     = !contains(aws_vpc_endpoint.s3.route_table_ids, aws_route_table.this["db"].id)
    error_message = "The db route table is attached to the S3 endpoint, so the db tier has a route out."
  }

  assert {
    condition     = length(aws_route_table.this["db"].route) == 0
    error_message = "The db route table has inline routes."
  }

  assert {
    condition     = aws_route.public_internet.route_table_id == aws_route_table.this["public"].id
    error_message = "The internet gateway route must be in the public route table only."
  }

  assert {
    condition = alltrue([
      for key, association in aws_route_table_association.this :
      association.route_table_id == aws_route_table.this[local.subnets[key].tier].id
      && association.subnet_id == aws_subnet.this[key].id
    ])
    error_message = "A subnet uses the route table of another tier."
  }
}

run "app_tier_reaches_s3_through_the_endpoint" {
  assert {
    condition     = contains(aws_vpc_endpoint.s3.route_table_ids, aws_route_table.this["app"].id)
    error_message = "The app route table is not attached to the S3 endpoint."
  }
}

run "subnets_are_private_and_in_two_zones" {
  assert {
    condition     = alltrue([for subnet in aws_subnet.this : !subnet.map_public_ip_on_launch])
    error_message = "A subnet hands out public IPs."
  }

  assert {
    condition     = length(aws_subnet.this) == 6 && length(distinct([for subnet in aws_subnet.this : subnet.cidr_block])) == 6
    error_message = "Expected 6 subnets with 6 different ranges."
  }

  assert {
    condition = alltrue([
      for tier in ["public", "app", "db"] :
      length(distinct([for key, subnet in aws_subnet.this : subnet.availability_zone if local.subnets[key].tier == tier])) == 2
    ])
    error_message = "Every tier must be spread over two availability zones (RDS needs it)."
  }
}

run "default_security_group_stays_empty" {
  assert {
    condition     = length(aws_default_security_group.locked.ingress) == 0 && length(aws_default_security_group.locked.egress) == 0
    error_message = "The default security group must have no rules."
  }
}

run "flow_logs_record_everything_in_a_private_bucket" {
  assert {
    condition     = aws_flow_log.vpc.traffic_type == "ALL"
    error_message = "Flow logs must record accepted and rejected traffic."
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.flow_logs.block_public_acls,
      aws_s3_bucket_public_access_block.flow_logs.block_public_policy,
      aws_s3_bucket_public_access_block.flow_logs.ignore_public_acls,
      aws_s3_bucket_public_access_block.flow_logs.restrict_public_buckets,
    ])
    error_message = "The flow log bucket must block all public access."
  }
}

run "rejects_one_availability_zone" {
  command = plan

  variables {
    az_count = 1
  }

  expect_failures = [var.az_count]
}

run "rejects_an_invalid_range" {
  command = plan

  variables {
    vpc_cidr = "not-a-range"
  }

  expect_failures = [var.vpc_cidr]
}
