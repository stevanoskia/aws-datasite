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
  # The real traffic files, so that the document test below covers them too
  loadgen_files = { for name in fileset("../../../loadgen", "*.{js,json}") : name => file("../../../loadgen/${name}") }
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
      k6         = "grafana/k6:2.4.0@sha256:d41bb79cd8de5a7ad619b53570e3712633e8bff0937010a5c6c57a4747e7a276"
    }
  }

  expect_failures = [var.images]
}

run "background_traffic_reports_to_the_monitoring_server" {
  assert {
    condition     = strcontains(output.app_compose, "\n  traffic:\n") && strcontains(output.app_compose, "PROFILE: background")
    error_message = "With a rate above 0, the app server must run the background traffic."
  }

  assert {
    condition = (
      strcontains(output.app_compose, "K6_OTEL_HTTP_EXPORTER_ENDPOINT: 10.30.11.20:9090\n")
      && strcontains(output.app_compose, "K6_OTEL_HTTP_EXPORTER_URL_PATH: /api/v1/otlp/v1/metrics\n")
    )
    error_message = "k6 must send to Prometheus' OpenTelemetry receiver on the monitoring server (host and port, no scheme)."
  }

  assert {
    condition     = strcontains(output.app_compose, "RATE: \"1.5\"\n")
    error_message = "The traffic must use the rate given to the module."
  }

  assert {
    condition = (
      local.app_files["loadgen/shop.js"] == file("../../../loadgen/shop.js")
      && local.app_files["loadgen/profiles.json"] == file("../../../loadgen/profiles.json")
    )
    error_message = "The traffic files must reach the app server unchanged (not rendered as templates)."
  }
}

run "no_background_traffic_at_rate_zero" {
  variables {
    background_rate = 0
  }

  assert {
    condition     = !strcontains(output.app_compose, "traffic:") && strcontains(output.app_compose, "\n  alloy:\n")
    error_message = "Rate 0 must remove the traffic container and keep the collector."
  }
}

run "rejects_background_traffic_without_its_files" {
  command = plan

  variables {
    loadgen_files = {}
  }

  expect_failures = [var.background_rate]
}

run "rejects_a_background_rate_that_is_a_load_test" {
  command = plan

  variables {
    background_rate = 20
  }

  expect_failures = [var.background_rate]
}
