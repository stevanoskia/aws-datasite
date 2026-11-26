# Offline tests: the AWS provider is mocked, so nothing is created and no login is needed.
# They check what the policies say about the CI users and roles themselves. They do not check
# what a role created BY the apply role could do; that needs the IAM policy simulator.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/test-boundary" }
  }
}

variables {
  name_prefix          = "test"
  state_bucket_arn     = "arn:aws:s3:::test-state"
  deploy_document_name = "test-deploy"
}

run "users_can_only_assume_their_own_role" {
  assert {
    condition = (
      jsondecode(aws_iam_user_policy.plan_assume.policy).Statement[0].Resource == aws_iam_role.plan.arn
      && jsondecode(aws_iam_user_policy.apply_assume.policy).Statement[0].Resource == aws_iam_role.apply.arn
    )
    error_message = "A CI user can assume a role that is not its own."
  }

  assert {
    condition = alltrue([
      for policy in [aws_iam_user_policy.plan_assume.policy, aws_iam_user_policy.apply_assume.policy] :
      length(jsondecode(policy).Statement) == 1
      && toset(jsondecode(policy).Statement[0].Action) == toset(["sts:AssumeRole", "sts:TagSession"])
    ])
    error_message = "The CI users must have no permission except assuming their role."
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.plan.assume_role_policy).Statement[0].Principal.AWS == aws_iam_user.plan.arn
      && jsondecode(aws_iam_role.apply.assume_role_policy).Statement[0].Principal.AWS == aws_iam_user.apply.arn
    )
    error_message = "A CI role trusts something other than its own user."
  }
}

run "sessions_last_one_hour_at_most" {
  assert {
    condition     = aws_iam_role.plan.max_session_duration <= 3600 && aws_iam_role.apply.max_session_duration <= 3600
    error_message = "CI sessions must not last longer than one hour."
  }
}

run "plan_role_writes_only_lock_files" {
  assert {
    condition     = endswith(aws_iam_role_policy_attachment.plan_readonly.policy_arn, ":policy/ReadOnlyAccess")
    error_message = "The plan role must only have the read-only managed policy."
  }

  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.plan_state_lock.policy).Statement) == 1
      && jsondecode(aws_iam_role_policy.plan_state_lock.policy).Statement[0].Resource == "arn:aws:s3:::test-state/*.tflock"
    )
    error_message = "The plan role may only write *.tflock files."
  }
}

run "apply_role_guardrails_are_present" {
  assert {
    condition = length(setsubtract(
      ["iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile", "iam:DeleteRolePermissionsBoundary", "ssm:StartSession", "s3:DeleteBucket"],
      flatten([for s in jsondecode(aws_iam_role_policy.apply_guardrails.policy).Statement : s.Action if can(s.Action)])
    )) == 0
    error_message = "An explicit deny is missing from the guardrails."
  }

  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_role_policy.apply_guardrails.policy).Statement : s.Effect == "Deny"])
    error_message = "The guardrail policy must contain denies only."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.apply_guardrails.policy).Statement :
      toset(flatten([s.Resource])) == toset([
        "arn:aws:iam::123456789012:user/test-ci-*",
        "arn:aws:iam::123456789012:role/test-ci-*",
        "arn:aws:iam::123456789012:policy/test-boundary",
      ])
    ])
    error_message = "The CI users, CI roles and the boundary must be protected from changes by CI."
  }
}

run "new_roles_need_the_boundary" {
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.apply_iam_scoped.policy).Statement :
      try(s.Condition.StringEquals["iam:PermissionsBoundary"] == aws_iam_policy.boundary.arn, false)
      if length(setintersection(flatten([s.Action]), ["iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy"])) > 0
    ])
    error_message = "Roles can be created or extended without the permissions boundary."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_policy.boundary.policy).Statement :
      contains(s.NotAction, "iam:*") if can(s.NotAction)
    ])
    error_message = "The boundary must not allow IAM changes."
  }
}
