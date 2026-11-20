# The daily-use role for reaching the private servers (app, Grafana, psql) with
# SSM Session Manager port forwarding. Sessions can only be started:
#   - by the trusted admin role (you switch into this role from your login),
#   - on instances tagged project=<project_tag>,
#   - from the allowed public IP ranges (office / company VPN).
# The full admin role stays the break-glass path if these IPs ever change.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  # Session documents the operator may use: shell, and port forwarding to the instance
  # itself or through it to another host (e.g. RDS)
  session_documents = [
    "arn:aws:ssm:${local.region}:${local.account_id}:document/SSM-SessionManagerRunShell",
    "arn:aws:ssm:${local.region}::document/AWS-StartPortForwardingSession",
    "arn:aws:ssm:${local.region}::document/AWS-StartPortForwardingSessionToRemoteHost",
  ]
}

resource "aws_iam_role" "operator" {
  name                 = "${var.name_prefix}-operator"
  description          = "Daily access to the private servers via SSM, only from allowed IPs"
  max_session_duration = var.max_session_seconds
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
      Action    = ["sts:AssumeRole", "sts:SetSourceIdentity"]
      Condition = {
        ArnLike = { "aws:PrincipalArn" = var.trusted_role_arns }
      }
    }]
  })
}

resource "aws_iam_role_policy" "operator_sessions" {
  name = "ssm-sessions-from-allowed-ips"
  role = aws_iam_role.operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Start a session only on project instances, and only from the allowed IPs
        Sid      = "StartSessionOnProjectInstances"
        Effect   = "Allow"
        Action   = ["ssm:StartSession"]
        Resource = "arn:aws:ec2:${local.region}:${local.account_id}:instance/*"
        Condition = {
          StringEquals = { "ssm:resourceTag/project" = var.project_tag }
          IpAddress    = { "aws:SourceIp" = var.allowed_source_cidrs }
        }
      },
      {
        Sid      = "UseSessionDocuments"
        Effect   = "Allow"
        Action   = ["ssm:StartSession"]
        Resource = local.session_documents
        Condition = {
          IpAddress = { "aws:SourceIp" = var.allowed_source_cidrs }
        }
      },
      {
        # Only your own sessions can be resumed or ended
        Sid      = "ManageOwnSessions"
        Effect   = "Allow"
        Action   = ["ssm:ResumeSession", "ssm:TerminateSession"]
        Resource = "arn:aws:ssm:${local.region}:${local.account_id}:session/$${aws:userid}-*"
      },
      {
        Sid    = "FindInstances"
        Effect = "Allow"
        Action = [
          "ssm:DescribeInstanceInformation",
          "ssm:DescribeSessions",
          "ssm:GetConnectionStatus",
          "ec2:DescribeInstances",
        ]
        Resource = "*"
      },
    ]
  })
}
