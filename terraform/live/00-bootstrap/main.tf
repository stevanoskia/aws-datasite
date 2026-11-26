# 00-bootstrap: the pieces everything else depends on.
# Applied by hand from the laptop (never by CI), because it creates the CI access itself.

# -----------------------------------------------------------------------------
# 1. Terraform state bucket
# -----------------------------------------------------------------------------

# Bucket names are global across all AWS accounts, so we add a random suffix
# instead of the account ID (the account ID must not appear in the public repo).
resource "random_id" "state_suffix" {
  byte_length = 3 # 3 bytes = 6 hex characters, e.g. "a1b2c3"
}

locals {
  state_bucket_name = "${var.project}-tfstate-${random_id.state_suffix.hex}"
}

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  # Terraform refuses to destroy this bucket: losing the state means Terraform
  # forgets everything it created.
  lifecycle {
    prevent_destroy = true
  }
}

# Every write keeps the previous version, so a broken state can be restored
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Encryption at rest with S3-managed keys (free; a customer KMS key would cost $1/month)
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block every form of public access, even if someone adds a public policy by mistake
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACLs off: only IAM policies decide access
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Refuse any request that is not HTTPS
data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

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

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  # The public access block must exist first, otherwise S3 may reject the policy call
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# Old state versions are kept 90 days, then deleted (keeps storage cost at ~0)
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {} # empty filter = applies to every object

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Lifecycle rules on a versioned bucket need versioning switched on first
  depends_on = [aws_s3_bucket_versioning.state]
}

# -----------------------------------------------------------------------------
# 2. Alerts topic: one place where all alerts go (CloudWatch alarms, Grafana later)
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"
}

# Email subscription. AWS sends a confirmation email: click the link in it,
# otherwise no alert is delivered.
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# -----------------------------------------------------------------------------
# 3. Monthly budget (credits excluded, otherwise every cost would look like $0)
# -----------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit = false # show the real usage, before credits pay for it
    include_refund = false
  }

  # One email per threshold on ACTUAL spend: 50%, 80%, 100%
  dynamic "notification" {
    for_each = var.budget_thresholds_pct

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.alert_email]
    }
  }

  # And one early warning when the FORECAST for the month goes over 100%
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# -----------------------------------------------------------------------------
# 4. CI access: IAM users + roles that GitHub Actions uses (keys created by hand)
# -----------------------------------------------------------------------------

module "ci_access" {
  source = "../../modules/ci-access"

  name_prefix          = var.project
  state_bucket_arn     = aws_s3_bucket.state.arn
  deploy_document_name = "datasite-deploy" # made by 30-app (module app-deploy)
}
