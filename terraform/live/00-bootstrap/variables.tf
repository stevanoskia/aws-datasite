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

variable "alert_email" {
  description = "Email that receives budget and alert notifications"
  type        = string
  sensitive   = true # hidden in plan/apply output, so it never reaches public CI logs
}

variable "monthly_budget_usd" {
  description = "Monthly budget limit in USD, credits excluded"
  type        = number
  default     = 45
}

variable "budget_thresholds_pct" {
  description = "Percent of the budget at which an email is sent (actual spend)"
  type        = list(number)
  default     = [50, 80, 100]
}
