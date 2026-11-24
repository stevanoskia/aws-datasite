variable "name_prefix" {
  description = "Prefix for resource names, e.g. aws-datasite"
  type        = string
}

variable "vpc_id" {
  description = "VPC of the database"
  type        = string
}

variable "subnet_ids" {
  description = "Private db subnets"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "RDS needs subnets in at least two availability zones."
  }
}

variable "availability_zone" {
  description = "Zone of the instance (same as the app server: no cross-zone latency or cost)"
  type        = string
}

variable "client_security_group_id" {
  description = "The only security group that may connect"
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL version"
  type        = string
  default     = "18.6"
}

variable "instance_class" {
  description = "Instance class (the Free plan allows micro only)"
  type        = string
  default     = "db.t4g.micro"
}

variable "storage_gb" {
  description = "Disk size in GB. It can grow later, but never shrink"
  type        = number
  default     = 20
}

variable "database_name" {
  description = "Database created with the instance"
  type        = string
  default     = "shop"
}

variable "backup_retention_days" {
  description = "Days of automated backups (the Free plan allows 1)"
  type        = number
  default     = 1

  validation {
    condition     = var.backup_retention_days >= 1
    error_message = "Automated backups must stay on (at least 1 day)."
  }
}
