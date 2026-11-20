provider "aws" {
  region = var.region

  # No "profile" here on purpose: profile names must not go to GitHub.
  # Terraform reads the profile from the AWS_PROFILE environment variable instead.

  # These tags are added automatically to every resource this stack creates
  default_tags {
    tags = {
      project    = var.project
      layer      = "00-bootstrap"
      managed_by = "terraform"
    }
  }
}
