# Offline tests: the AWS provider is mocked, so nothing is created and no login is needed.

mock_provider "aws" {
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-0123456789abcdef0" }
  }
}

variables {
  name_prefix              = "test"
  name                     = "app"
  subnet_id                = "subnet-0123456789abcdef0"
  security_group_id        = "sg-0123456789abcdef0"
  permissions_boundary_arn = "arn:aws:iam::123456789012:policy/test-boundary"
}

run "server_is_private_and_hardened" {
  assert {
    condition     = aws_instance.host.associate_public_ip_address == false
    error_message = "The server must not have a public IP."
  }

  assert {
    condition     = toset(aws_instance.host.vpc_security_group_ids) == toset([var.security_group_id])
    error_message = "The server must use exactly the given security group."
  }

  assert {
    condition     = aws_instance.host.metadata_options[0].http_tokens == "required" && aws_instance.host.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "IMDSv2 must be required and unreachable from containers."
  }

  assert {
    condition     = aws_instance.host.root_block_device[0].encrypted
    error_message = "The disk must be encrypted."
  }
}

run "role_has_only_ssm_and_the_boundary" {
  assert {
    condition     = aws_iam_role.host.permissions_boundary == var.permissions_boundary_arn
    error_message = "The role must carry the permissions boundary."
  }

  assert {
    condition     = endswith(aws_iam_role_policy_attachment.host_ssm.policy_arn, ":policy/AmazonSSMManagedInstanceCore")
    error_message = "The role must only have the SSM agent policy."
  }
}

run "startup_script_is_complete" {
  assert {
    condition     = startswith(aws_instance.host.user_data, "#!/bin/bash\n")
    error_message = "The startup script must begin with the shebang, otherwise cloud-init does not run it."
  }

  assert {
    condition     = strcontains(aws_instance.host.user_data, "dnf install -y docker") && strcontains(aws_instance.host.user_data, "systemctl enable --now docker")
    error_message = "Docker must be installed and started."
  }

  assert {
    condition     = strcontains(aws_instance.host.user_data, "${var.compose_sha256}  /tmp/docker-compose\" | sha256sum -c -")
    error_message = "The Docker Compose download must be checked against its checksum."
  }
}

run "rejects_an_invalid_checksum" {
  command = plan

  variables {
    compose_sha256 = "abc"
  }

  expect_failures = [var.compose_sha256]
}
