# How a new version of the app reaches the app server:
#
#   pipeline ──push──> image registry (ECR) <──pull── app server
#   pipeline ──SSM Run Command "deploy" (one input: the commit)──> app server: check database, start, test, else roll back
#   pipeline ──SSM Run Command "migrate" (apply role only, after an approval)──> app server: run the migrations
#
# The scripts are fixed here; the pipeline can only choose the version. The server's rights to pull images and
# read the database address are added to its role.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  region    = data.aws_region.current.region
  arn_end   = "${local.region}:${data.aws_caller_identity.current.account_id}"
  container = "${var.name_prefix}-app"

  # Values for the scripts, put in front of them as shell variables
  settings = {
    REPOSITORY           = aws_ecr_repository.app.repository_url
    REGION               = local.region
    DB_ADDRESS_PARAMETER = var.db_address_parameter
    STATE                = "/etc/shop"
    RUN_DIR              = "/run"  # in memory: gone after a restart
    APP_UID              = "10001" # the user the app's image runs as
    CONTAINER            = local.container
    PORT                 = tostring(var.app_port)
  }

  scripts = {
    deploy  = merge(local.settings, { APP_SECRET = var.app_secret_name })
    migrate = merge(local.settings, { MIGRATE_SECRET = var.migrate_secret_name })
  }
}

# --- Image registry -------------------------------------------------------------------------

resource "aws_ecr_repository" "app" {
  name                 = "${var.name_prefix}/app"
  image_tag_mutability = "IMMUTABLE" # a version, once pushed, is never replaced: a rollback gets exactly what was tested

  image_scanning_configuration {
    scan_on_push = true # known vulnerabilities of the system packages (basic scanning, free)
  }

  force_delete = true # the images can be built again from Git; a destroy must not be blocked by them
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the newest images only"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = var.images_to_keep }
      action       = { type = "expire" }
    }]
  })
}

# --- Rights of the app server ---------------------------------------------------------------

resource "aws_iam_role_policy" "host" {
  name = "pull-images-read-db-address"
  role = var.host_role_name

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
        Sid      = "PullFromThisRepository"
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = aws_ecr_repository.app.arn
      },
      {
        Sid      = "ReadTheDatabaseAddress"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${local.arn_end}:parameter${var.db_address_parameter}"
      },
    ]
  })
}

# --- The fixed scripts ----------------------------------------------------------------------

resource "aws_ssm_document" "this" {
  for_each = local.scripts

  name            = "${var.document_prefix}-${each.key}"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "${each.key} a version of the app (fixed script, see terraform/modules/app-deploy/scripts)"
    parameters = {
      ImageTag = {
        type           = "String"
        description    = "Git commit of the version"
        allowedPattern = "^[0-9a-f]{40}$"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = each.key
      inputs = {
        timeoutSeconds = "900"
        runCommand = concat(
          ["#!/bin/bash"],
          [for name, value in each.value : "${name}='${value}'"],
          split("\n", trimspace(file("${path.module}/scripts/${each.key}.sh"))),
        )
      }
    }]
  })
}
