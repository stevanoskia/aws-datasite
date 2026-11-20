# A NAT instance: a small EC2 instance that forwards outbound traffic from the private
# app subnets to the internet and sends the answers back. Nothing on the internet can
# start a connection inwards (no inbound rule from outside the VPC).
#
# Instead of a NAT gateway (≈ $34/month) it costs ≈ $0.008/h + $0.005/h for the public IPv4.
# Trade-off: one instance = single point of failure for outbound traffic, no auto-healing.

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# --- Security group: accept only from the private subnets, send anywhere -----------------

resource "aws_security_group" "nat" {
  name        = "${var.name_prefix}-nat"
  description = "NAT instance: inbound only from the private app subnets"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-nat"
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_private" {
  for_each = toset(var.client_cidrs)

  security_group_id = aws_security_group.nat.id
  description       = "All traffic from private subnet ${each.value}"
  ip_protocol       = "-1"
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "to_internet" {
  security_group_id = aws_security_group.nat.id
  description       = "Forward traffic to the internet"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- IAM: SSM agent only (so the instance can be inspected without SSH) ------------------

resource "aws_iam_role" "nat" {
  name                 = "${var.name_prefix}-nat"
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

resource "aws_iam_role_policy_attachment" "nat_ssm" {
  role       = aws_iam_role.nat.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "nat" {
  name = "${var.name_prefix}-nat"
  role = aws_iam_role.nat.name
}

# --- The instance ---------------------------------------------------------------------

resource "aws_instance" "nat" {
  ami                  = data.aws_ssm_parameter.al2023_arm64.insecure_value # public AMI ID, not a secret
  instance_type        = var.instance_type
  subnet_id            = var.subnet_id
  iam_instance_profile = aws_iam_instance_profile.nat.name

  vpc_security_group_ids      = [aws_security_group.nat.id]
  associate_public_ip_address = true  # auto-assigned (released when stopped); an Elastic IP would cost money while stopped
  source_dest_check           = false # required: the instance forwards packets that are not addressed to itself

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  # Turn the instance into a router at boot: enable IP forwarding and masquerade (source NAT)
  # traffic from the private subnets behind the instance's own public IP.
  user_data_replace_on_change = true
  user_data                   = <<-EOT
    #!/bin/bash
    set -euo pipefail
    dnf install -y iptables-services
    echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/90-nat.conf
    sysctl --system
    iface="$(ip route show default | awk '{print $5; exit}')"
    iptables -t nat -F POSTROUTING
    %{for cidr in var.client_cidrs~}
    iptables -t nat -A POSTROUTING -o "$iface" -s ${cidr} -j MASQUERADE
    %{endfor~}
    iptables -F FORWARD
    iptables -P FORWARD DROP
    iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    %{for cidr in var.client_cidrs~}
    iptables -A FORWARD -s ${cidr} -j ACCEPT
    %{endfor~}
    service iptables save
    systemctl enable --now iptables
  EOT

  tags = {
    Name = "${var.name_prefix}-nat"
  }

  lifecycle {
    ignore_changes = [ami] # a newer AMI shouldn't replace the router on every plan; update on purpose
  }
}
