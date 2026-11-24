variable "name_prefix" {
  description = "Prefix for resource names, e.g. aws-datasite"
  type        = string
}

variable "name" {
  description = "Short name of what is scheduled, e.g. nat or app"
  type        = string
}

variable "instance_ids" {
  description = "EC2 instances to start and stop (either these or db_instance_id)"
  type        = list(string)
  default     = []

  validation {
    condition     = (length(var.instance_ids) > 0) != (var.db_instance_id != null)
    error_message = "Give either instance_ids or db_instance_id."
  }
}

variable "db_instance_id" {
  description = "RDS instance to start and stop (either this or instance_ids)"
  type        = string
  default     = null
}

variable "start_cron" {
  description = "When to start (EventBridge Scheduler cron)"
  type        = string
  default     = "cron(0 7 ? * MON-FRI *)"
}

variable "stop_cron" {
  description = "When to stop. Every day, so a server started by hand on a weekend is stopped too"
  type        = string
  default     = "cron(0 19 * * ? *)"
}

variable "timezone" {
  description = "Time zone of both schedules (follows summer time)"
  type        = string
  default     = "Europe/Berlin"
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary every project IAM role must carry"
  type        = string
}
