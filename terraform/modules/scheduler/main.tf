# Starts and stops EC2 instances or one RDS instance on a schedule, to save cost outside working hours.
# EventBridge Scheduler calls the AWS API directly, so no Lambda function is needed.
# The role may start and stop exactly the given instances and nothing else.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  full_name = "${var.name_prefix}-schedule-${var.name}"

  is_db   = var.db_instance_id != null
  arn_end = "${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}"

  actions   = local.is_db ? ["rds:StartDBInstance", "rds:StopDBInstance"] : ["ec2:StartInstances", "ec2:StopInstances"]
  resources = local.is_db ? ["arn:aws:rds:${local.arn_end}:db:${var.db_instance_id}"] : [for id in var.instance_ids : "arn:aws:ec2:${local.arn_end}:instance/${id}"]

  start_target = local.is_db ? "arn:aws:scheduler:::aws-sdk:rds:startDBInstance" : "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
  stop_target  = local.is_db ? "arn:aws:scheduler:::aws-sdk:rds:stopDBInstance" : "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
  input        = local.is_db ? jsonencode({ DbInstanceIdentifier = var.db_instance_id }) : jsonencode({ InstanceIds = var.instance_ids })
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
      Action   = local.actions
      Resource = local.resources
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
    arn      = local.start_target
    role_arn = aws_iam_role.scheduler.arn
    input    = local.input
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
    arn      = local.stop_target
    role_arn = aws_iam_role.scheduler.arn
    input    = local.input
  }
}
