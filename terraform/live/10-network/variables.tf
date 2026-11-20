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
