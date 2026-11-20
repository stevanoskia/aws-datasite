variable "name_prefix" {
  description = "Prefix for resource names, e.g. aws-datasite"
  type        = string
}

variable "vpc_cidr" {
  description = "IPv4 range of the VPC"
  type        = string
  default     = "10.30.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block, e.g. 10.30.0.0/16."
  }
}

variable "az_count" {
  description = "How many availability zones to spread the subnets over (RDS needs at least 2)"
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "flow_log_retention_days" {
  description = "Days to keep VPC flow log files in S3"
  type        = number
  default     = 30
}

variable "flow_log_aggregation_seconds" {
  description = "Flow log aggregation interval: 60 (more detail, more records) or 600"
  type        = number
  default     = 60

  validation {
    condition     = contains([60, 600], var.flow_log_aggregation_seconds)
    error_message = "Must be 60 or 600."
  }
}
