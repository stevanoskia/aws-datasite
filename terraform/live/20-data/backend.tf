# State in the shared S3 bucket, key "20-data/terraform.tfstate".
# The settings come from backend.hcl (git-ignored locally; written from secrets in CI).
terraform {
  backend "s3" {}
}
