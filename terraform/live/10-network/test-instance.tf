# A small, temporary instance in a private app subnet, used to prove the isolation from the inside:
# outbound works only through the NAT instance, nothing can connect in, SSM works without open ports.
# Switch off with test_instance_enabled = false once the proofs are documented.

data "aws_ssm_parameter" "al2023_arm64" {
  count = var.test_instance_enabled ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_security_group" "test" {
  count = var.test_instance_enabled ? 1 : 0

  name        = "${var.project}-test"
  description = "Test instance: no inbound at all, outbound HTTPS/HTTP only"
  vpc_id      = module.network.vpc_id

  tags = {
    Name = "${var.project}-test"
  }
}

# No ingress rules at all. Outbound: HTTPS (SSM, AWS APIs, package repos) and HTTP (proof tests).
resource "aws_vpc_security_group_egress_rule" "test_https" {
  count = var.test_instance_enabled ? 1 : 0

  security_group_id = aws_security_group.test[0].id
  description       = "HTTPS out (SSM agent, AWS APIs, packages)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "test_http" {
  count = var.test_instance_enabled ? 1 : 0

  security_group_id = aws_security_group.test[0].id
  description       = "HTTP out (proof tests)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_iam_role" "test" {
  count = var.test_instance_enabled ? 1 : 0

  name                 = "${var.project}-test"
  permissions_boundary = data.aws_iam_policy.boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "test_ssm" {
  count = var.test_instance_enabled ? 1 : 0

  role       = aws_iam_role.test[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "test" {
  count = var.test_instance_enabled ? 1 : 0

  name = "${var.project}-test"
  role = aws_iam_role.test[0].name
}

resource "aws_instance" "test" {
  count = var.test_instance_enabled ? 1 : 0

  ami                    = data.aws_ssm_parameter.al2023_arm64[0].insecure_value
  instance_type          = "t4g.micro"
  subnet_id              = module.network.app_subnet_ids[0]
  iam_instance_profile   = aws_iam_instance_profile.test[0].name
  vpc_security_group_ids = [aws_security_group.test[0].id]

  associate_public_ip_address = false

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  tags = {
    Name = "${var.project}-test"
  }

  lifecycle {
    ignore_changes = [ami]
  }

  # The route through the NAT instance must exist before the SSM agent starts
  depends_on = [aws_route.app_to_nat]
}
