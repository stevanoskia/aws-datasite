# State in the shared S3 bucket, key "30-app/terraform.tfstate".
# The settings come from backend.hcl (git-ignored locally; written from secrets in CI).
terraform {
  backend "s3" {}
}
