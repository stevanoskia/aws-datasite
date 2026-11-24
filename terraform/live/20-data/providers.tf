provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project    = var.project
      layer      = "20-data"
      managed_by = "terraform"
    }
  }
}
