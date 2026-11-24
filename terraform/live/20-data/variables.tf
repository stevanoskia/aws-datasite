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

variable "state_bucket" {
  description = "Terraform state bucket, to read the network stack. Local: terraform.tfvars; CI: secret TF_STATE_BUCKET"
  type        = string
}

variable "instance_az_index" {
  description = "Availability zone of the database: 0 = a, 1 = b (same zone as the app server)"
  type        = number
  default     = 1

  validation {
    condition     = contains([0, 1], var.instance_az_index)
    error_message = "Must be 0 (zone a) or 1 (zone b)."
  }
}
