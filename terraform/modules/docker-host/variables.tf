variable "name_prefix" {
  description = "Prefix for resource names, e.g. aws-datasite"
  type        = string
}

variable "name" {
  description = "Short name of the server, e.g. app"
  type        = string
}

variable "subnet_id" {
  description = "Private subnet the server runs in"
  type        = string
}

variable "security_group_id" {
  description = "Security group of the server"
  type        = string
}

variable "instance_type" {
  description = "Instance type (free-tier-eligible ARM)"
  type        = string
  default     = "t4g.small"
}

variable "volume_size" {
  description = "Disk size in GB"
  type        = number
  default     = 16
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary every project IAM role must carry"
  type        = string
}

variable "compose_version" {
  description = "Docker Compose version"
  type        = string
  default     = "5.8.0"
}

variable "compose_sha256" {
  description = "Published SHA-256 of docker-compose-linux-aarch64 in that version"
  type        = string
  default     = "1a9c918b2fb49b9c87f0018c64b5abd0d30715155e98dc939779fbaee6c414d3"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.compose_sha256))
    error_message = "Must be a SHA-256 checksum (64 hex characters)."
  }
}
