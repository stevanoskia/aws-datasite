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
    k6         = string
  })
  default = {
    prometheus = "prom/prometheus:v3.16.0@sha256:e04987641b57704f408e31f6373ba4138ecf27cb4a165d24aabb6c38fddd0f06"
    grafana    = "grafana/grafana:13.3.2@sha256:81556409ba48b2b922e0adb69a2511337d8ba7578f11962eefa6149a2d815101"
    alloy      = "grafana/alloy:v1.22.0@sha256:9acc2529bc1edb7f5b2bd801dd8334ebc80c158e3a9e5526ecd7c9a273d43189"
    k6         = "grafana/k6:2.4.0@sha256:d41bb79cd8de5a7ad619b53570e3712633e8bff0937010a5c6c57a4747e7a276"
  }

  validation {
    condition     = alltrue([for image in values(var.images) : can(regex("@sha256:[0-9a-f]{64}$", image))])
    error_message = "Every image must be pinned by its digest (name:tag@sha256:...)."
  }
}

variable "background_rate" {
  description = "Requests per second of the background traffic on the app server (loadgen, profile background); 0 = none"
  type        = number
  default     = 1.5

  validation {
    condition     = var.background_rate >= 0 && var.background_rate <= 5
    error_message = "Background traffic is 0 to 5 requests per second (load tests run separately)."
  }

  validation {
    condition     = var.background_rate == 0 || alltrue([for name in ["shop.js", "profiles.json"] : contains(keys(var.loadgen_files), name)])
    error_message = "Background traffic needs loadgen_files with shop.js and profiles.json."
  }
}

variable "loadgen_files" {
  description = "The traffic generator's files (loadgen/ in the repository), by file name; written to the app server"
  type        = map(string)
  default     = {}
}
