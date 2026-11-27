variable "name_prefix" {
  description = "Prefix for resource names, e.g. aws-datasite"
  type        = string
}

variable "document_prefix" {
  description = "Prefix of the SSM document names, e.g. datasite (gives datasite-obs-stack, datasite-app-stack)"
  type        = string

  validation {
    condition     = !can(regex("^(aws|amazon|amzn)", lower(var.document_prefix)))
    error_message = "SSM document names that start with aws, amazon or amzn are reserved by AWS (CreateDocument fails)."
  }
}

variable "vpc_id" {
  description = "VPC of the monitoring server"
  type        = string
}

variable "subnet_id" {
  description = "Private subnet of the monitoring server"
  type        = string
}

variable "app_security_group_id" {
  description = "Security group of the app server, the only sender to Prometheus"
  type        = string
}

variable "app_instance_id" {
  description = "App server, which gets the collector"
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary every project IAM role must carry"
  type        = string
}

variable "instance_type" {
  description = "Instance type of the monitoring server (free-tier-eligible ARM)"
  type        = string
  default     = "t4g.small"
}

variable "volume_size" {
  description = "Disk of the monitoring server in GB (Prometheus is capped at 12 GB of it)"
  type        = number
  default     = 20
}

variable "prometheus_port" {
  description = "Port of Prometheus on the monitoring server"
  type        = number
  default     = 9090
}

variable "grafana_port" {
  description = "Port of Grafana on the monitoring server's localhost"
  type        = number
  default     = 3000
}

variable "app_port" {
  description = "Port of the app on the app server's localhost"
  type        = number
  default     = 8000
}

variable "images" {
  description = "Container images, pinned by digest"
  type = object({
    prometheus = string
    grafana    = string
    alloy      = string
  })
  default = {
    prometheus = "prom/prometheus:v3.16.0@sha256:e04987641b57704f408e31f6373ba4138ecf27cb4a165d24aabb6c38fddd0f06"
    grafana    = "grafana/grafana:13.3.2@sha256:81556409ba48b2b922e0adb69a2511337d8ba7578f11962eefa6149a2d815101"
    alloy      = "grafana/alloy:v1.22.0@sha256:9acc2529bc1edb7f5b2bd801dd8334ebc80c158e3a9e5526ecd7c9a273d43189"
  }

  validation {
    condition     = alltrue([for image in values(var.images) : can(regex("@sha256:[0-9a-f]{64}$", image))])
    error_message = "Every image must be pinned by its digest (name:tag@sha256:...)."
  }
}
