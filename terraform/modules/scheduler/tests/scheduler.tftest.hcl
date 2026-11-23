# Offline tests: the AWS provider is mocked, so nothing is created and no login is needed.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "eu-north-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/test" }
  }
}

variables {
  name_prefix              = "test"
  name                     = "nat"
  instance_ids             = ["i-0aaaaaaaaaaaaaaaa"]
  permissions_boundary_arn = "arn:aws:iam::123456789012:policy/test-boundary"
}

run "role_can_only_start_and_stop_the_given_instances" {
  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.scheduler.policy).Statement) == 1
      && toset(jsondecode(aws_iam_role_policy.scheduler.policy).Statement[0].Action) == toset(["ec2:StartInstances", "ec2:StopInstances"])
      && toset(jsondecode(aws_iam_role_policy.scheduler.policy).Statement[0].Resource) == toset(["arn:aws:ec2:eu-north-1:123456789012:instance/i-0aaaaaaaaaaaaaaaa"])
    )
    error_message = "The role may do more than start and stop exactly these instances."
  }

  assert {
    condition     = aws_iam_role.scheduler.permissions_boundary == var.permissions_boundary_arn
    error_message = "The role must carry the permissions boundary."
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.scheduler.assume_role_policy).Statement[0].Principal.Service == "scheduler.amazonaws.com"
      && try(jsondecode(aws_iam_role.scheduler.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"], "") == "123456789012"
    )
    error_message = "Only EventBridge Scheduler of this account may use the role."
  }
}

run "stops_every_day_and_starts_on_weekdays" {
  assert {
    condition     = aws_scheduler_schedule.start.schedule_expression == "cron(0 7 ? * MON-FRI *)" && aws_scheduler_schedule.stop.schedule_expression == "cron(0 19 * * ? *)"
    error_message = "Expected start at 07:00 on weekdays and stop at 19:00 every day."
  }

  assert {
    condition     = endswith(aws_scheduler_schedule.start.target[0].arn, ":startInstances") && endswith(aws_scheduler_schedule.stop.target[0].arn, ":stopInstances")
    error_message = "The start and stop schedules are mixed up."
  }

  assert {
    condition = alltrue([
      for input in [aws_scheduler_schedule.start.target[0].input, aws_scheduler_schedule.stop.target[0].input] :
      jsondecode(input).InstanceIds[0] == "i-0aaaaaaaaaaaaaaaa" && length(jsondecode(input).InstanceIds) == 1
    ])
    error_message = "The schedules must name exactly the given instances."
  }
}

run "rejects_an_empty_list" {
  command = plan

  variables {
    instance_ids = []
  }

  expect_failures = [var.instance_ids]
}
