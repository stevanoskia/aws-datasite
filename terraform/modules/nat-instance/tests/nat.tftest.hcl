# Offline tests: the AWS provider is mocked, so nothing is created and no login is needed.

mock_provider "aws" {
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-0123456789abcdef0" }
  }
}

variables {
  name_prefix              = "test"
  vpc_id                   = "vpc-0123456789abcdef0"
  subnet_id                = "subnet-0123456789abcdef0"
  client_cidrs             = ["10.30.10.0/24", "10.30.11.0/24"]
  permissions_boundary_arn = "arn:aws:iam::123456789012:policy/test-boundary"
}

run "inbound_only_from_the_private_subnets" {
  assert {
    condition     = toset([for rule in aws_vpc_security_group_ingress_rule.from_private : rule.cidr_ipv4]) == toset(var.client_cidrs)
    error_message = "Inbound must be allowed from exactly the client ranges."
  }

  assert {
    condition     = length(aws_security_group.nat.ingress) == 0
    error_message = "The security group has inline inbound rules next to the separate ones."
  }
}

run "instance_can_route_and_is_hardened" {
  assert {
    condition     = aws_instance.nat.source_dest_check == false
    error_message = "A NAT instance needs source_dest_check = false to forward packets."
  }

  assert {
    condition     = aws_instance.nat.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required."
  }

  assert {
    condition     = aws_instance.nat.root_block_device[0].encrypted
    error_message = "The root volume must be encrypted."
  }

  assert {
    condition     = aws_iam_role.nat.permissions_boundary == var.permissions_boundary_arn
    error_message = "The role must carry the permissions boundary."
  }
}

run "startup_script_is_complete" {
  assert {
    condition     = startswith(aws_instance.nat.user_data, "#!/bin/bash\n")
    error_message = "The startup script must begin with the shebang, otherwise cloud-init does not run it."
  }

  assert {
    condition     = alltrue([for cidr in var.client_cidrs : strcontains(aws_instance.nat.user_data, "-s ${cidr} -j MASQUERADE")])
    error_message = "A client range is missing from the NAT rules."
  }

  assert {
    condition     = strcontains(aws_instance.nat.user_data, "iptables -P FORWARD DROP")
    error_message = "Forwarding must be denied by default."
  }
}
