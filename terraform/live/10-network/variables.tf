variable "region" {
  description = "AWS region for all regional resources"
  type        = string
  default     = "eu-north-1"
}

variable "project" {
  description = "Project name, used in resource names and tags"
  type        = string
  default     = "aws-datasite"
}

variable "vpc_cidr" {
  description = "IPv4 range of the project VPC"
  type        = string
  default     = "10.30.0.0/16"
}

variable "operator_allowed_cidrs" {
  description = "Public IP ranges (office / VPN egress) allowed to start SSM sessions. Local: terraform.tfvars; CI: secret OPERATOR_ALLOWED_CIDRS"
  type        = list(string)
  sensitive   = true
}

variable "operator_trusted_role_path_name" {
  description = "Path + name of the admin role allowed to switch into the operator role"
  type        = string
  default     = "managed/AccountFullAccessRole"
}

variable "instance_az_index" {
  description = "Availability zone of the NAT and test instance: 0 = a, 1 = b (change it when AWS has no capacity in one zone)"
  type        = number
  default     = 1

  validation {
    condition     = contains([0, 1], var.instance_az_index)
    error_message = "Must be 0 (zone a) or 1 (zone b)."
  }
}

variable "test_instance_enabled" {
  description = "Create the small test instance used for the phase 1 isolation proofs"
  type        = bool
  default     = true
}
