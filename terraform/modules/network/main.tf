# The project network: one VPC, three subnet tiers in two availability zones.
#
#   tier      route to the internet                     used by
#   public    internet gateway (in + out)               the NAT instance only
#   app       NAT instance (out only, set by the stack) app host, monitoring host, test instance
#   db        none at all                               RDS
#
# Every tier also reaches S3 through the free gateway endpoint, without the internet.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(sort(data.aws_availability_zones.available.names), 0, var.az_count)

  # /24 subnets carved out of the VPC range: public 10.30.0-2.0, app 10.30.10-12.0, db 10.30.20-22.0
  tiers = {
    public = 0
    app    = 10
    db     = 20
  }

  subnets = {
    for pair in setproduct(keys(local.tiers), range(var.az_count)) :
    "${pair[0]}-${pair[1]}" => {
      tier = pair[0]
      az   = local.azs[pair[1]]
      cidr = cidrsubnet(var.vpc_cidr, 8, local.tiers[pair[0]] + pair[1])
    }
  }
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------

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

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# -----------------------------------------------------------------------------
# Subnets (one per tier and AZ)
# -----------------------------------------------------------------------------

resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  # No subnet hands out public IPs automatically, not even "public": the NAT instance asks for one itself
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-${each.value.tier}-${substr(each.value.az, -1, 1)}"
    tier = each.value.tier
  }
}

# -----------------------------------------------------------------------------
# Route tables: one per tier. The app tier's internet route is added by the stack,
# because it points at the NAT instance (another module).
# -----------------------------------------------------------------------------

resource "aws_route_table" "this" {
  for_each = local.tiers

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-${each.key}-rt"
    tier = each.key
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.this["public"].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "this" {
  for_each = local.subnets

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.this[each.value.tier].id
}

# -----------------------------------------------------------------------------
# S3 gateway endpoint (free): S3 traffic from app and db stays on the AWS network
# -----------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.this["app"].id, aws_route_table.this["db"].id]

  tags = {
    Name = "${var.name_prefix}-s3-endpoint"
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# VPC flow logs → S3: every accepted and rejected connection, kept 30 days
# -----------------------------------------------------------------------------

resource "random_id" "flow_logs_suffix" {
  byte_length = 3
}

resource "aws_s3_bucket" "flow_logs" {
  bucket        = "${var.name_prefix}-flowlogs-${random_id.flow_logs_suffix.hex}"
  force_destroy = true # only logs inside; allows a clean teardown
}

resource "aws_s3_bucket_public_access_block" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  rule {
    id     = "expire-flow-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.flow_log_retention_days
    }
  }
}

# Lets the AWS log delivery service write into the bucket (only for this account's flow logs),
# and refuses any non-HTTPS access
data "aws_iam_policy_document" "flow_logs" {
  statement {
    sid       = "AWSLogDeliveryWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.flow_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "AWSLogDeliveryAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.flow_logs.arn]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.flow_logs.arn, "${aws_s3_bucket.flow_logs.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json

  depends_on = [aws_s3_bucket_public_access_block.flow_logs]
}

resource "aws_flow_log" "vpc" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL" # ACCEPT and REJECT
  log_destination_type     = "s3"
  log_destination          = aws_s3_bucket.flow_logs.arn
  max_aggregation_interval = var.flow_log_aggregation_seconds

  destination_options {
    file_format        = "plain-text"
    per_hour_partition = true
  }

  tags = {
    Name = "${var.name_prefix}-vpc-flow-log"
  }

  depends_on = [aws_s3_bucket_policy.flow_logs]
}
