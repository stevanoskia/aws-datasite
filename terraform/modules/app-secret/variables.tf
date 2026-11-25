variable "name_prefix" {
  description = "Prefix for resource names, e.g. aws-datasite"
  type        = string
}

variable "name" {
  description = "Short name of the secret, e.g. app-db"
  type        = string
}

variable "description" {
  description = "What the secret holds and how it is set"
  type        = string
}

variable "reader_role_name" {
  description = "IAM role that may read the value"
  type        = string
}

variable "reader_role_arn" {
  description = "ARN of the same role"
  type        = string
}
