variable "name_prefix" {
  description = "Prefix for every IAM name, e.g. aws-datasite"
  type        = string
}

variable "state_bucket_arn" {
  description = "ARN of the Terraform state bucket (plan may write lock files; apply may not change the bucket itself)"
  type        = string
}

variable "max_session_seconds" {
  description = "How long one assumed-role session from CI may last"
  type        = number
  default     = 3600
}
