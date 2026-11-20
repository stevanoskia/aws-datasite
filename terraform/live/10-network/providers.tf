provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project    = var.project
      layer      = "10-network"
      managed_by = "terraform"
    }
  }
}
