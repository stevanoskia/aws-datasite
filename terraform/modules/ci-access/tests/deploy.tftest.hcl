# Offline tests of the deploy user: what it may do without an approval.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { region = "eu-north-1" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/test-boundary" }
  }
}

variables {
  name_prefix      = "test"
  state_bucket_arn = "arn:aws:s3:::test-state"
}

run "the_user_can_only_assume_its_role" {
  assert {
    condition = (
      jsondecode(aws_iam_user_policy.deploy_assume.policy).Statement == [{
        Effect = "Allow", Action = ["sts:AssumeRole", "sts:TagSession"], Resource = aws_iam_role.deploy.arn
      }]
      && jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Principal.AWS == aws_iam_user.deploy.arn
      && aws_iam_role.deploy.max_session_duration <= 3600
    )
    error_message = "The deploy user must do nothing but assume its own role, for at most an hour."
  }
}

run "it_runs_only_the_deploy_script_and_only_on_the_app_server" {
  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Resource if s.Action == "ssm:SendCommand"
    ])) == toset(["arn:aws:ssm:eu-north-1:123456789012:document/test-deploy", "arn:aws:ec2:eu-north-1:123456789012:instance/*"])
    error_message = "The deploy role may run the deploy document only: not the migrate document, not a shell."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement :
      try(s.Condition.StringEquals["ssm:resourceTag/Name"] == "test-app", false)
      if s.Action == "ssm:SendCommand" && s.Resource == "arn:aws:ec2:eu-north-1:123456789012:instance/*"
    ])
    error_message = "The deploy script may run on the app server only."
  }
}

run "nothing_else" {
  assert {
    condition = toset(flatten([for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Action])) == toset([
      "ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages",
      "ssm:SendCommand", "ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:DescribeInstanceInformation",
    ])
    error_message = "The deploy role has a right it should not have (no sessions, secrets, parameters or other services)."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement :
      length(setsubtract(flatten([s.Action]), ["ecr:GetAuthorizationToken", "ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:DescribeInstanceInformation"])) == 0
      if s.Resource == "*"
    ])
    error_message = "Only actions without a resource may apply to every resource."
  }

  assert {
    condition = toset([
      for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Resource if contains(flatten([s.Action]), "ecr:PutImage")
    ]) == toset(["arn:aws:ecr:eu-north-1:123456789012:repository/test/app"])
    error_message = "Images may be pushed to the app's repository only."
  }
}

run "the_deploy_user_and_role_are_protected_from_the_apply_role" {
  assert {
    condition     = startswith(aws_iam_user.deploy.name, "test-ci-") && startswith(aws_iam_role.deploy.name, "test-ci-")
    error_message = "The deploy user and role must fall under the guardrail pattern test-ci-*, so CI can't change them."
  }
}
