# CI access for GitHub Actions without OIDC (OIDC providers are blocked by the account's SCP).
#
#   GitHub secret (access key) ──> IAM user  ──(sts:AssumeRole only)──> IAM role ──> real permissions
#
# The users can do nothing except assume their own role, so a leaked key alone gives
# 1-hour sessions with the role's limits, and every use shows up in CloudTrail by role name.
# Access keys are NOT created here (Terraform would store them in the state); they are
# created by hand and piped straight into GitHub secrets.

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  plan_name     = "${var.name_prefix}-ci-plan"
  apply_name    = "${var.name_prefix}-ci-apply"
  boundary_name = "${var.name_prefix}-boundary"

  # ARN patterns that CI must never be able to change (its own users, roles and the boundary)
  protected_iam_arns = [
    "arn:aws:iam::${local.account_id}:user/${var.name_prefix}-ci-*",
    "arn:aws:iam::${local.account_id}:role/${var.name_prefix}-ci-*",
    "arn:aws:iam::${local.account_id}:policy/${local.boundary_name}",
  ]
}

# -----------------------------------------------------------------------------
# Users: key-only (no console password), allowed only to assume their own role
# -----------------------------------------------------------------------------

resource "aws_iam_user" "plan" {
  name          = "${local.plan_name}-user"
  force_destroy = true # on destroy, also delete access keys that were created outside Terraform
}

resource "aws_iam_user" "apply" {
  name          = "${local.apply_name}-user"
  force_destroy = true
}

resource "aws_iam_user_policy" "plan_assume" {
  name = "assume-own-role-only"
  user = aws_iam_user.plan.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sts:AssumeRole", "sts:TagSession"]
      Resource = aws_iam_role.plan.arn
    }]
  })
}

resource "aws_iam_user_policy" "apply_assume" {
  name = "assume-own-role-only"
  user = aws_iam_user.apply.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sts:AssumeRole", "sts:TagSession"]
      Resource = aws_iam_role.apply.arn
    }]
  })
}

# -----------------------------------------------------------------------------
# Roles: each one trusts exactly one user
# -----------------------------------------------------------------------------

resource "aws_iam_role" "plan" {
  name                 = local.plan_name
  description          = "Read-only role for terraform plan in GitHub Actions"
  max_session_duration = var.max_session_seconds

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_user.plan.arn }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role" "apply" {
  name                 = local.apply_name
  description          = "Role for terraform apply and deploys in GitHub Actions (production environment only)"
  max_session_duration = var.max_session_seconds

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_user.apply.arn }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

# -----------------------------------------------------------------------------
# Plan role: read everything + write only the state lock file
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan_state_lock" {
  name = "state-lock-files"
  role = aws_iam_role.plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "WriteLockFilesOnly"
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:DeleteObject"]
      Resource = "${var.state_bucket_arn}/*.tflock"
    }]
  })
}

# -----------------------------------------------------------------------------
# Permissions boundary: the ceiling for every role the other stacks create.
# Even if CI creates a role with "*" permissions, the role can never do IAM
# changes, touch Organizations/account settings, or exceed this boundary.
# -----------------------------------------------------------------------------

resource "aws_iam_policy" "boundary" {
  name        = local.boundary_name
  description = "Permissions boundary for every IAM role created by the aws-datasite stacks"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowServicesButNotIam"
        Effect    = "Allow"
        NotAction = ["iam:*", "organizations:*", "account:*"]
        Resource  = "*"
      },
      {
        Sid      = "AllowIamReadAndPassRole"
        Effect   = "Allow"
        Action   = ["iam:Get*", "iam:List*", "iam:PassRole"]
        Resource = "*"
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Apply role: PowerUserAccess (everything except IAM/Organizations/account)
# + a narrow set of IAM rights + explicit denies (guardrails)
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy_attachment" "apply_poweruser" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "apply_iam_scoped" {
  name = "iam-scoped-to-project"
  role = aws_iam_role.apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "IamRead"
        Effect   = "Allow"
        Action   = ["iam:Get*", "iam:List*"]
        Resource = "*"
      },
      {
        # Creating roles or changing their permissions is allowed ONLY when the role
        # carries the project boundary, so CI can never create a role stronger than it
        Sid    = "ManageProjectRolesWithBoundary"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePermissionsBoundary",
        ]
        Resource = "arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*"
        Condition = {
          StringEquals = { "iam:PermissionsBoundary" = aws_iam_policy.boundary.arn }
        }
      },
      {
        Sid    = "ManageProjectRolesOther"
        Effect = "Allow"
        Action = [
          "iam:DeleteRole",
          "iam:UpdateRole",
          "iam:UpdateRoleDescription",
          "iam:UpdateAssumeRolePolicy",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:PassRole",
        ]
        Resource = "arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*"
      },
      {
        Sid    = "ManageProjectInstanceProfiles"
        Effect = "Allow"
        Action = [
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:TagInstanceProfile",
          "iam:UntagInstanceProfile",
        ]
        Resource = "arn:aws:iam::${local.account_id}:instance-profile/${var.name_prefix}-*"
      },
      {
        Sid    = "ManageProjectPolicies"
        Effect = "Allow"
        Action = [
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:TagPolicy",
          "iam:UntagPolicy",
        ]
        Resource = "arn:aws:iam::${local.account_id}:policy/${var.name_prefix}-*"
      },
      {
        # e.g. the RDS enhanced-monitoring or ECS service-linked roles
        Sid      = "ServiceLinkedRoles"
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "apply_guardrails" {
  name = "guardrails-deny"
  role = aws_iam_role.apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # No new IAM users, keys or passwords from CI, ever
        Sid    = "DenyIamUsersAndKeys"
        Effect = "Deny"
        Action = [
          "iam:CreateUser",
          "iam:CreateAccessKey",
          "iam:UpdateAccessKey",
          "iam:CreateLoginProfile",
          "iam:UpdateLoginProfile",
          "iam:AttachUserPolicy",
          "iam:PutUserPolicy",
          "iam:AddUserToGroup",
        ]
        Resource = "*"
      },
      {
        # CI can't change its own users, roles or the boundary (no privilege escalation)
        Sid       = "DenyChangesToCiAndBoundary"
        Effect    = "Deny"
        NotAction = ["iam:Get*", "iam:List*"]
        Resource  = local.protected_iam_arns
      },
      {
        # Removing a boundary from a role would lift its ceiling
        Sid      = "DenyBoundaryRemoval"
        Effect   = "Deny"
        Action   = ["iam:DeleteRolePermissionsBoundary"]
        Resource = "*"
      },
      {
        # CI deploys with SSM Run Command; it never needs interactive or port-forwarding sessions
        Sid      = "DenyInteractiveSessions"
        Effect   = "Deny"
        Action   = ["ssm:StartSession", "ssm:ResumeSession"]
        Resource = "*"
      },
      {
        # The state bucket itself is managed only by 00-bootstrap (by hand)
        Sid    = "DenyStateBucketChanges"
        Effect = "Deny"
        Action = [
          "s3:DeleteBucket",
          "s3:PutBucketPolicy",
          "s3:DeleteBucketPolicy",
          "s3:PutBucketVersioning",
          "s3:PutLifecycleConfiguration",
          "s3:PutEncryptionConfiguration",
          "s3:PutBucketPublicAccessBlock",
        ]
        Resource = var.state_bucket_arn
      },
    ]
  })
}
