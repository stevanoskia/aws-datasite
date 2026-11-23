# Starts and stops EC2 instances on a schedule, to save cost outside working hours.
# EventBridge Scheduler calls the EC2 API directly, so no Lambda function is needed.
# The role may start and stop exactly the given instances and nothing else.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  full_name = "${var.name_prefix}-schedule-${var.name}"

  instance_arns = [
    for id in var.instance_ids :
    "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/${id}"
  ]
}

resource "aws_iam_role" "scheduler" {
  name                 = local.full_name
  description          = "Lets EventBridge Scheduler start and stop the ${var.name} instances"
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "start-stop-these-instances"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "StartStop"
      Effect   = "Allow"
      Action   = ["ec2:StartInstances", "ec2:StopInstances"]
      Resource = local.instance_arns
    }]
  })
}

# Schedules can't carry tags, but their group can
resource "aws_scheduler_schedule_group" "this" {
  name = local.full_name
}

resource "aws_scheduler_schedule" "start" {
  name                         = "${local.full_name}-start"
  group_name                   = aws_scheduler_schedule_group.this.name
  schedule_expression          = var.start_cron
  schedule_expression_timezone = var.timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ InstanceIds = var.instance_ids })
  }
}

resource "aws_scheduler_schedule" "stop" {
  name                         = "${local.full_name}-stop"
  group_name                   = aws_scheduler_schedule_group.this.name
  schedule_expression          = var.stop_cron
  schedule_expression_timezone = var.timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ InstanceIds = var.instance_ids })
  }
}
