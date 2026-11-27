variable "name_prefix" {
  description = "Prefix for resource names, e.g. aws-datasite"
  type        = string
}

variable "trusted_role_arns" {
  description = "IAM roles (full ARN incl. path) whose sessions may assume the operator role"
  type        = list(string)
}

variable "allowed_source_cidrs" {
  description = "Public IP ranges (office / VPN egress) from which sessions may be started. Kept out of the repo."
  type        = list(string)
  sensitive   = true

  validation {
    condition     = length(var.allowed_source_cidrs) > 0 && alltrue([for c in var.allowed_source_cidrs : can(cidrhost(c, 0))])
    error_message = "Give at least one valid CIDR, e.g. 203.0.113.10/32."
  }
}

variable "project_tag" {
  description = "Value of the 'project' tag on the instances the operator may connect to"
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary every project IAM role must carry"
  type        = string
}

variable "max_session_seconds" {
  description = "Maximum role session length (role chaining from a login session caps it at 1 hour anyway)"
  type        = number
  default     = 3600
}

variable "idle_session_minutes" {
  description = "Minutes without traffic after which Session Manager ends a session (AWS allows 1-60)"
  type        = number
  default     = 60

  validation {
    condition     = var.idle_session_minutes >= 1 && var.idle_session_minutes <= 60 && floor(var.idle_session_minutes) == var.idle_session_minutes
    error_message = "Give whole minutes from 1 to 60."
  }
}
