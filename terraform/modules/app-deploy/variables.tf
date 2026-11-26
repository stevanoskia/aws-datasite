variable "name_prefix" {
  description = "Prefix for resource names, e.g. aws-datasite"
  type        = string
}

variable "host_role_name" {
  description = "IAM role of the app server, which pulls the images and runs the scripts"
  type        = string
}

variable "db_address_parameter" {
  description = "Name of the SSM parameter with the database address, e.g. /datasite/db/address"
  type        = string

  validation {
    condition     = startswith(var.db_address_parameter, "/")
    error_message = "Must be a parameter path starting with /."
  }

  validation {
    condition     = !can(regex("^/?(aws|ssm)", lower(var.db_address_parameter)))
    error_message = "Names that start with aws or ssm are reserved by AWS (an apply fails with AccessDenied)."
  }
}

variable "app_secret_name" {
  description = "Secret with the app's database login"
  type        = string
}

variable "migrate_secret_name" {
  description = "Secret with the migration login, which owns the tables"
  type        = string
}

variable "app_port" {
  description = "Port of the app on the server (localhost only)"
  type        = number
  default     = 8000
}

variable "images_to_keep" {
  description = "Newest images kept in the registry: versions to roll back to"
  type        = number
  default     = 20
}
