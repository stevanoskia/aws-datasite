# Offline tests: the AWS provider is mocked, so nothing is created and no login is needed.

mock_provider "aws" {
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:eu-north-1:123456789012:secret:test/app-db-AbCdEf" }
  }
}

variables {
  name_prefix      = "test"
  name             = "app-db"
  description      = "test"
  reader_role_name = "test-app"
  reader_role_arn  = "arn:aws:iam::123456789012:role/test-app"
}

run "only_the_reader_can_read" {
  assert {
    condition = jsondecode(aws_secretsmanager_secret_policy.reader_only.policy).Statement == [{
      Sid       = "DenyReadingExceptOneRole"
      Effect    = "Deny"
      Principal = "*"
      Action    = "secretsmanager:GetSecretValue"
      Resource  = "*"
      Condition = { StringNotEquals = { "aws:PrincipalArn" = "arn:aws:iam::123456789012:role/test-app" } }
    }]
    error_message = "Everybody except the reader role must be denied."
  }

  assert {
    condition     = aws_secretsmanager_secret_policy.reader_only.secret_arn == aws_secretsmanager_secret.this.arn
    error_message = "The deny must be attached to this secret."
  }
}

run "the_reader_gets_nothing_else" {
  assert {
    condition = jsondecode(aws_iam_role_policy.reader.policy).Statement == [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = "arn:aws:secretsmanager:eu-north-1:123456789012:secret:test/app-db-AbCdEf"
    }]
    error_message = "The role may read this one secret and nothing else."
  }

  assert {
    condition     = aws_iam_role_policy.reader.role == "test-app"
    error_message = "The right must go to the reader role."
  }
}
