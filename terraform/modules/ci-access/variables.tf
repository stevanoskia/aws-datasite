variable "name_prefix" {
  description = "Prefix for every IAM name, e.g. aws-datasite"
  type        = string
}

variable "state_bucket_arn" {
  description = "ARN of the Terraform state bucket (plan may write lock files; apply may not change the bucket itself)"
  type        = string
}

variable "deploy_document_name" {
  description = "The only SSM document the deploy user may run (made by the app-deploy module in 30-app)"
  type        = string

  validation {
    condition     = !can(regex("^(aws|amazon|amzn)", lower(var.deploy_document_name)))
    error_message = "SSM document names that start with aws, amazon or amzn are reserved by AWS (CreateDocument fails)."
  }
}

variable "max_session_seconds" {
  description = "How long one assumed-role session from CI may last"
  type        = number
  default     = 3600
}
