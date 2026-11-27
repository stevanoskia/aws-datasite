# Offline tests: the AWS provider is mocked, so nothing is created and no login is needed.
# What the containers do is checked in scripts/tests/test_observability_files.py, and on the servers.

mock_provider "aws" {
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-0123456789abcdef0" }
  }
  mock_resource "aws_instance" {
    defaults = { id = "i-0obs0000000000000", private_ip = "10.30.11.20" }
  }
  mock_resource "aws_ssm_document" {
    defaults = { latest_version = "3" }
  }
}

variables {
  name_prefix              = "test"
  document_prefix          = "datasite"
  vpc_id                   = "vpc-0123456789abcdef0"
  subnet_id                = "subnet-0123456789abcdef0"
  app_security_group_id    = "sg-0app0000000000000"
  app_instance_id          = "i-0app0000000000000"
  permissions_boundary_arn = "arn:aws:iam::123456789012:policy/test-boundary"
}

run "only_the_app_server_reaches_prometheus" {
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.prometheus_from_app.referenced_security_group_id == var.app_security_group_id
      && aws_vpc_security_group_ingress_rule.prometheus_from_app.cidr_ipv4 == null
      && aws_vpc_security_group_ingress_rule.prometheus_from_app.from_port == 9090
      && aws_vpc_security_group_ingress_rule.prometheus_from_app.to_port == 9090
    )
    error_message = "Prometheus must accept port 9090 from the app server's security group only."
  }

  assert {
    condition = (
      aws_vpc_security_group_egress_rule.app_to_prometheus.security_group_id == var.app_security_group_id
      && aws_vpc_security_group_egress_rule.app_to_prometheus.referenced_security_group_id == aws_security_group.obs.id
      && aws_vpc_security_group_egress_rule.app_to_prometheus.from_port == 9090
    )
    error_message = "The app server may send to the monitoring server's port 9090 only."
  }
}

run "the_collector_sends_to_the_monitoring_server" {
  assert {
    condition     = strcontains(local.app_files["config.alloy"], "url = \"http://10.30.11.20:9090/api/v1/write\"")
    error_message = "Alloy must send to Prometheus on the monitoring server's private address."
  }
}

run "each_server_gets_its_own_configuration" {
  assert {
    condition     = tolist(aws_ssm_association.stack["obs"].targets[0].values) == tolist([module.host.instance_id])
    error_message = "The monitoring stack must run on the monitoring server."
  }

  assert {
    condition     = tolist(aws_ssm_association.stack["app"].targets[0].values) == tolist([var.app_instance_id])
    error_message = "The collector must run on the app server."
  }

  assert {
    condition     = alltrue([for key in ["obs", "app"] : aws_ssm_association.stack[key].document_version == aws_ssm_document.stack[key].latest_version])
    error_message = "An association must follow the newest version of its document, or a changed file never reaches the server."
  }

  assert {
    condition     = alltrue([for key in ["obs", "app"] : aws_ssm_association.stack[key].wait_for_success_timeout_seconds > 0])
    error_message = "The apply must wait for the servers, so a broken configuration fails it."
  }
}

run "documents_contain_no_parameter_syntax" {
  # SSM reads {{ }} as a document parameter: CreateDocument fails, or the text is replaced
  assert {
    condition     = alltrue([for key in ["obs", "app"] : !strcontains(aws_ssm_document.stack[key].content, "{{")])
    error_message = "A document contains {{ }}; SSM would read it as a parameter."
  }
}

run "rejects_a_reserved_document_prefix" {
  command = plan

  variables {
    document_prefix = "aws-datasite"
  }

  expect_failures = [var.document_prefix]
}

run "rejects_an_image_without_digest" {
  command = plan

  variables {
    images = {
      prometheus = "prom/prometheus:latest"
      grafana    = "grafana/grafana:13.3.2@sha256:81556409ba48b2b922e0adb69a2511337d8ba7578f11962eefa6149a2d815101"
      alloy      = "grafana/alloy:v1.22.0@sha256:9acc2529bc1edb7f5b2bd801dd8334ebc80c158e3a9e5526ecd7c9a273d43189"
    }
  }

  expect_failures = [var.images]
}
