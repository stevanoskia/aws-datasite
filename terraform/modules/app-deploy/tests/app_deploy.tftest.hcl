# Offline tests: the AWS provider is mocked, so nothing is created and no login is needed.
# The scripts themselves are tested in scripts/tests/test_deploy_scripts.py.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { region = "eu-north-1" }
  }
  mock_resource "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:eu-north-1:123456789012:repository/test/app"
      repository_url = "123456789012.dkr.ecr.eu-north-1.amazonaws.com/test/app"
    }
  }
}

variables {
  name_prefix          = "test"
  document_prefix      = "testshop"
  host_role_name       = "test-app"
  db_address_parameter = "/test/db/address"
  app_secret_name      = "test/app-db"
  migrate_secret_name  = "test/migrate-db"
}

run "a_version_is_never_replaced" {
  assert {
    condition     = aws_ecr_repository.app.image_tag_mutability == "IMMUTABLE"
    error_message = "Image tags must be immutable: a rollback must get exactly what was tested."
  }

  assert {
    condition     = aws_ecr_repository.app.image_scanning_configuration[0].scan_on_push
    error_message = "Images must be scanned when they are pushed."
  }
}

run "the_only_input_is_a_commit" {
  assert {
    condition = alltrue([
      for document in aws_ssm_document.this :
      keys(jsondecode(document.content).parameters) == ["ImageTag"]
      && jsondecode(document.content).parameters.ImageTag.allowedPattern == "^[0-9a-f]{40}$"
    ])
    error_message = "A document takes something other than a commit as input: that input would end up in a shell script."
  }

  assert {
    condition     = toset(keys(aws_ssm_document.this)) == toset(["deploy", "migrate"])
    error_message = "Exactly the deploy and the migrate document are expected."
  }
}

run "each_script_gets_only_its_own_secret" {
  assert {
    condition = (
      contains(jsondecode(aws_ssm_document.this["deploy"].content).mainSteps[0].inputs.runCommand, "APP_SECRET='test/app-db'")
      && !strcontains(aws_ssm_document.this["deploy"].content, "test/migrate-db")
      && contains(jsondecode(aws_ssm_document.this["migrate"].content).mainSteps[0].inputs.runCommand, "MIGRATE_SECRET='test/migrate-db'")
      && !strcontains(aws_ssm_document.this["migrate"].content, "test/app-db")
    )
    error_message = "The deploy script must not get the migration login, nor the other way round."
  }

  assert {
    condition = alltrue([
      for document in aws_ssm_document.this :
      jsondecode(document.content).mainSteps[0].inputs.runCommand[0] == "#!/bin/bash"
      && contains(jsondecode(document.content).mainSteps[0].inputs.runCommand, "set -euo pipefail")
    ])
    error_message = "The scripts must run in bash and stop at the first error."
  }
}

run "the_server_may_pull_from_this_registry_only" {
  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.host.policy).Statement :
      statement.Resource == "*" ? statement.Action == "ecr:GetAuthorizationToken" : true
    ])
    error_message = "Only the login to the registry may apply to every resource."
  }

  assert {
    condition = toset(flatten([
      for statement in jsondecode(aws_iam_role_policy.host.policy).Statement : statement.Action
    ])) == toset(["ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ssm:GetParameter"])
    error_message = "The server must be able to pull and read the address, nothing else (no push, no other parameters)."
  }

  assert {
    condition = contains([
      for statement in jsondecode(aws_iam_role_policy.host.policy).Statement : statement.Resource
    ], "arn:aws:ssm:eu-north-1:123456789012:parameter/test/db/address")
    error_message = "The server may read the database address parameter, and only that one."
  }
}

run "the_documents_are_named_after_their_prefix" {
  assert {
    condition     = aws_ssm_document.this["deploy"].name == "testshop-deploy" && aws_ssm_document.this["migrate"].name == "testshop-migrate"
    error_message = "The documents must be called <document_prefix>-deploy and <document_prefix>-migrate: the deploy user's rights name them."
  }
}

run "rejects_a_reserved_document_prefix" {
  command = plan

  variables {
    document_prefix = "Amazon-shop"
  }

  expect_failures = [var.document_prefix]
}

run "rejects_a_reserved_parameter_name" {
  command = plan

  variables {
    db_address_parameter = "/AWS-project/db/address"
  }

  expect_failures = [var.db_address_parameter]
}

run "rejects_a_relative_parameter_name" {
  command = plan

  variables {
    db_address_parameter = "test/db/address"
  }

  expect_failures = [var.db_address_parameter]
}
