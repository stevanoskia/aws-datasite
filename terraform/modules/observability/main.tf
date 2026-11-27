# The monitoring server, and the collector on the app server that feeds it:
#
#   app server: Alloy ──scrapes──> app /metrics (localhost) and the server itself (CPU, memory, disk, network)
#               Alloy, k6 ──remote write :9090──> monitoring server: Prometheus <── Grafana (localhost:3000, through the tunnel only)
#
# Nothing on the monitoring server accepts a connection except Prometheus' port, and only from the app server's
# security group. Grafana listens on the server's localhost: the SSM tunnel (operator role, company address) is its door.
#
# The configuration files live in files/. Terraform puts them into two SSM documents, and an association runs each
# document on its server whenever the files change: config change -> plan -> approval -> apply -> servers updated.

locals {
  full_name = "${var.name_prefix}-obs"

  # Values the files need, filled in by templatefile()
  values = {
    prometheus_port = var.prometheus_port
    grafana_port    = var.grafana_port
    app_port        = var.app_port
    images          = var.images
  }

  prometheus_address = "${module.host.private_ip}:${var.prometheus_port}"

  obs_files = {
    "compose.yaml"                                     = templatefile("${path.module}/files/obs/compose.yaml", local.values)
    "prometheus.yml"                                   = file("${path.module}/files/obs/prometheus.yml")
    "grafana/provisioning/datasources/prometheus.yaml" = file("${path.module}/files/obs/grafana/datasources.yaml")
    "grafana/provisioning/dashboards/files.yaml"       = file("${path.module}/files/obs/grafana/dashboards.yaml")
    "grafana/dashboards/service.json"                  = file("${path.module}/files/obs/grafana/service.json")
    "grafana/dashboards/host.json"                     = file("${path.module}/files/obs/grafana/host.json")
  }

  app_compose = templatefile("${path.module}/files/app/compose.yaml", merge(local.values, {
    background_rate = var.background_rate
    otlp_endpoint   = local.prometheus_address # k6 wants host and port only
  }))

  app_files = merge(
    {
      "compose.yaml" = local.app_compose
      "config.alloy" = templatefile("${path.module}/files/app/config.alloy", merge(local.values, {
        remote_write_url = "http://${local.prometheus_address}/api/v1/write"
      }))
    },
    { for name, content in var.loadgen_files : "loadgen/${name}" => content },
  )

  # Each server gets: its files (compressed), then install.sh, which starts the compose project
  documents = {
    obs = { project = "datasite-obs", files = local.obs_files, instance_id = module.host.instance_id }
    app = { project = "datasite-agents", files = local.app_files, instance_id = var.app_instance_id }
  }

  # The folder of each file on the Linux server. Not dirname(): on Windows it returns "grafana\dashboards"
  directory = { for path in setunion(keys(local.obs_files), keys(local.app_files)) :
    path => length(split("/", path)) > 1 ? join("/", slice(split("/", path), 0, length(split("/", path)) - 1)) : "."
  }
}

# --- The server ----------------------------------------------------------------------------

resource "aws_security_group" "obs" {
  name        = local.full_name
  description = "Monitoring server: Prometheus from the app server only, outbound HTTPS"
  vpc_id      = var.vpc_id

  tags = {
    Name = local.full_name
  }
}

resource "aws_vpc_security_group_ingress_rule" "prometheus_from_app" {
  security_group_id            = aws_security_group.obs.id
  description                  = "Remote write from the app server (Alloy, k6)"
  ip_protocol                  = "tcp"
  from_port                    = var.prometheus_port
  to_port                      = var.prometheus_port
  referenced_security_group_id = var.app_security_group_id
}

resource "aws_vpc_security_group_egress_rule" "obs_https" {
  security_group_id = aws_security_group.obs.id
  description       = "HTTPS out (SSM, images)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# The app server may send to Prometheus (its group has outbound HTTPS and database rules only)
resource "aws_vpc_security_group_egress_rule" "app_to_prometheus" {
  security_group_id            = var.app_security_group_id
  description                  = "Remote write to Prometheus on the monitoring server"
  ip_protocol                  = "tcp"
  from_port                    = var.prometheus_port
  to_port                      = var.prometheus_port
  referenced_security_group_id = aws_security_group.obs.id
}

module "host" {
  source = "../docker-host"

  name_prefix              = var.name_prefix
  name                     = "obs"
  subnet_id                = var.subnet_id
  security_group_id        = aws_security_group.obs.id
  instance_type            = var.instance_type
  volume_size              = var.volume_size
  permissions_boundary_arn = var.permissions_boundary_arn
}

# --- Configuration on both servers ---------------------------------------------------------

resource "aws_ssm_document" "stack" {
  for_each = local.documents

  name            = "${var.document_prefix}-${each.key}-stack"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Write the ${each.value.project} files and start its containers (terraform/modules/observability/files)"
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "install"
      inputs = {
        timeoutSeconds = "900"
        runCommand = concat(
          ["#!/bin/bash", "set -euo pipefail", "PROJECT='${each.value.project}'", "new=\"$(mktemp -d)\""],
          flatten([for path, content in each.value.files : [
            "mkdir -p \"$new/${local.directory[path]}\"",
            "echo '${base64gzip(content)}' | base64 -d | gunzip > \"$new/${path}\"",
          ]]),
          split("\n", trimspace(file("${path.module}/scripts/install.sh"))),
        )
      }
    }]
  })
}

# Runs the document when it is created, whenever a new version replaces it, and on a new server.
# The apply waits until it has succeeded, so a broken configuration fails the apply instead of staying unnoticed.
resource "aws_ssm_association" "stack" {
  for_each = local.documents

  association_name                 = "${var.document_prefix}-${each.key}-stack"
  name                             = aws_ssm_document.stack[each.key].name
  document_version                 = aws_ssm_document.stack[each.key].latest_version
  wait_for_success_timeout_seconds = 900

  targets {
    key    = "InstanceIds"
    values = [each.value.instance_id]
  }

  # Terraform waits for success only when it creates an association: an updated one still shows the last run's status.
  # A new association for every changed document makes each change wait, so a broken configuration fails the apply.
  lifecycle {
    replace_triggered_by = [aws_ssm_document.stack[each.key].content]
  }
}
