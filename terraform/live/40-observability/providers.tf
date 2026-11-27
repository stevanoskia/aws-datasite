provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project    = var.project
      layer      = "40-observability"
      managed_by = "terraform"
    }
  }
}
