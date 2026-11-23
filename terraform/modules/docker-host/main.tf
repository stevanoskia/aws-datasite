# A private Linux server with Docker and Docker Compose, reached only through SSM.
# No public IP, no SSH key, no inbound rule (its security group comes from the network stack).

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  full_name = "${var.name_prefix}-${var.name}"
}

# --- IAM: SSM agent only ---------------------------------------------------------------

resource "aws_iam_role" "host" {
  name                 = local.full_name
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "host_ssm" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "host" {
  name = local.full_name
  role = aws_iam_role.host.name
}

# --- The server ------------------------------------------------------------------------

resource "aws_instance" "host" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.insecure_value # public AMI ID, not a secret
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  iam_instance_profile   = aws_iam_instance_profile.host.name
  vpc_security_group_ids = [var.security_group_id]

  associate_public_ip_address = false

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # containers can't reach the server's AWS credentials
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.volume_size
    encrypted   = true
  }

  # Runs once, at the first boot. The NAT instance must be running, so downloads are retried.
  user_data_replace_on_change = true
  user_data                   = <<-EOT
    #!/bin/bash
    set -euo pipefail

    retry() {
      for attempt in $(seq 1 30); do
        "$@" && return 0
        echo "attempt $attempt failed: $*"
        sleep 10
      done
      return 1
    }

    retry dnf install -y docker

    # Keep container logs small and containers running while Docker itself restarts
    mkdir -p /etc/docker
    echo '{"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}, "live-restore": true}' > /etc/docker/daemon.json

    # Docker Compose is not in the Amazon Linux repositories: pinned version, checked against a pinned checksum
    plugins=/usr/local/lib/docker/cli-plugins
    mkdir -p "$plugins"
    retry curl -fsSL -o /tmp/docker-compose "https://github.com/docker/compose/releases/download/v${var.compose_version}/docker-compose-linux-aarch64"
    echo "${var.compose_sha256}  /tmp/docker-compose" | sha256sum -c -
    install -m 0755 /tmp/docker-compose "$plugins/docker-compose"

    systemctl enable --now docker
  EOT

  tags = {
    Name = local.full_name
  }

  lifecycle {
    ignore_changes = [ami] # a newer AMI shouldn't replace the server on every plan; update on purpose
  }
}
