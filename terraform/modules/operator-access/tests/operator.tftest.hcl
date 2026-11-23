# Offline tests: the AWS provider is mocked, so nothing is created and no login is needed.
# They check what the policy says. That a session really opens is tested against AWS.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "eu-north-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}

variables {
  name_prefix              = "test"
  project_tag              = "test-project"
  trusted_role_arns        = ["arn:aws:iam::123456789012:role/admin"]
  allowed_source_cidrs     = ["203.0.113.10/32"]
  permissions_boundary_arn = "arn:aws:iam::123456789012:policy/test-boundary"
}

run "sessions_start_only_from_the_allowed_addresses" {
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.operator_sessions.policy).Statement :
      try(s.Condition.IpAddress["aws:SourceIp"] == ["203.0.113.10/32"], false)
      if contains(flatten([s.Action]), "ssm:StartSession")
    ])
    error_message = "A statement allows ssm:StartSession without the source IP condition."
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.operator_sessions.policy).Statement : s
      if contains(flatten([s.Action]), "ssm:StartSession")
    ]) == 2
    error_message = "Expected two StartSession statements: instances and session documents."
  }
}

run "sessions_start_only_on_project_instances" {
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.operator_sessions.policy).Statement :
      try(s.Condition.StringEquals["ssm:resourceTag/project"] == "test-project", false)
      if contains(flatten([s.Action]), "ssm:StartSession") && strcontains(jsonencode(s.Resource), ":instance/")
    ])
    error_message = "Sessions must be limited to instances with the project tag."
  }
}

run "only_own_sessions_can_be_used" {
  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.operator_sessions.policy).Statement :
      contains(flatten([s.Action]), "ssmmessages:OpenDataChannel")
    ])
    error_message = "ssmmessages:OpenDataChannel is missing."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.operator_sessions.policy).Statement :
      try(s.Condition.StringEquals["ssm:resourceTag/aws:ssmmessages:session-id"] == "$${aws:userid}", false)
      if length(setintersection(flatten([s.Action]), ["ssm:ResumeSession", "ssm:TerminateSession", "ssmmessages:OpenDataChannel"])) > 0
    ])
    error_message = "Session permissions must be limited to the caller's own sessions."
  }
}

run "no_wildcard_actions" {
  assert {
    condition = alltrue([
      for action in flatten([for s in jsondecode(aws_iam_role_policy.operator_sessions.policy).Statement : s.Action]) :
      !strcontains(action, "*")
    ])
    error_message = "The operator policy must name every action."
  }
}

run "only_the_admin_role_may_switch_into_it" {
  assert {
    condition     = jsondecode(aws_iam_role.operator.assume_role_policy).Statement[0].Condition.ArnLike["aws:PrincipalArn"] == ["arn:aws:iam::123456789012:role/admin"]
    error_message = "The trust policy must be limited to the trusted roles."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role.operator.assume_role_policy).Statement) == 1
    error_message = "The trust policy must have exactly one statement."
  }

  assert {
    condition     = aws_iam_role.operator.permissions_boundary == var.permissions_boundary_arn
    error_message = "The role must carry the permissions boundary."
  }
}

run "rejects_an_empty_address_list" {
  command = plan

  variables {
    allowed_source_cidrs = []
  }

  expect_failures = [var.allowed_source_cidrs]
}

run "rejects_an_invalid_address" {
  command = plan

  variables {
    allowed_source_cidrs = ["not-an-address"]
  }

  expect_failures = [var.allowed_source_cidrs]
}
