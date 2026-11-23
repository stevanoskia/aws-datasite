provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project    = var.project
      layer      = "30-app"
      managed_by = "terraform"
    }
  }
}
