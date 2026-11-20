variable "name_prefix" {
  description = "Prefix for resource names, e.g. aws-datasite"
  type        = string
}

variable "vpc_id" {
  description = "VPC the NAT instance serves"
  type        = string
}

variable "subnet_id" {
  description = "Public subnet the NAT instance runs in"
  type        = string
}

variable "client_cidrs" {
  description = "Private subnet ranges allowed to send traffic through the NAT instance"
  type        = list(string)
}

variable "instance_type" {
  description = "Instance type (free-tier-eligible ARM: t4g.micro)"
  type        = string
  default     = "t4g.micro"
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary every project IAM role must carry"
  type        = string
}
