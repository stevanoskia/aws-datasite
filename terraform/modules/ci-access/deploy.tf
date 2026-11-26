# Deploy access: the third CI user, for automatic app deploys WITHOUT an approval (its key is a repository secret).
# So it can do very little: push images to the app's registry, and run the fixed deploy script on the app server.
# It can't run the migrate script (that needs the apply role, after an approval), open a shell, or read secrets.

data "aws_region" "current" {}

locals {
  deploy_name = "${var.name_prefix}-ci-deploy"
  arn_end     = "${data.aws_region.current.region}:${local.account_id}"
}

resource "aws_iam_user" "deploy" {
  name          = "${local.deploy_name}-user"
  force_destroy = true
}

resource "aws_iam_user_policy" "deploy_assume" {
  name = "assume-own-role-only"
  user = aws_iam_user.deploy.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sts:AssumeRole", "sts:TagSession"]
      Resource = aws_iam_role.deploy.arn
    }]
  })
}

resource "aws_iam_role" "deploy" {
  name                 = local.deploy_name
  description          = "Role for automatic app deploys in GitHub Actions: push images, run the fixed deploy script"
  max_session_duration = var.max_session_seconds

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_user.deploy.arn }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "deploy" {
  name = "push-images-run-deploy-script"
  role = aws_iam_role.deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "LogInToTheRegistry"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*" # this action has no resource
      },
      {
        Sid    = "PushToTheAppRepository"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:DescribeImages",
        ]
        Resource = "arn:aws:ecr:${local.arn_end}:repository/${var.name_prefix}/app"
      },
      {
        # SSM checks the document and the server separately: the document must be the deploy script ...
        Sid      = "RunOnlyTheDeployScript"
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = "arn:aws:ssm:${local.arn_end}:document/${var.deploy_document_name}"
      },
      {
        # ... and the server must be the app server
        Sid       = "RunItOnlyOnTheAppServer"
        Effect    = "Allow"
        Action    = "ssm:SendCommand"
        Resource  = "arn:aws:ec2:${local.arn_end}:instance/*"
        Condition = { StringEquals = { "ssm:resourceTag/Name" = "${var.name_prefix}-app" } }
      },
      {
        Sid      = "SeeTheResult"
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:DescribeInstanceInformation"]
        Resource = "*" # these actions have no resource
      },
    ]
  })
}
