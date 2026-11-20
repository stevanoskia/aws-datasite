# Where Terraform keeps the state of this stack: the S3 bucket this stack itself created.
# The settings (bucket name, key, region) come from backend.hcl, which is git-ignored:
#   terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {}
}
