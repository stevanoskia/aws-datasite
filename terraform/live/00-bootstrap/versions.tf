terraform {
  # 1.10+ is needed for state locking with a plain S3 file (use_lockfile), no DynamoDB table
  required_version = ">= 1.10"

  required_providers {
    # A "provider" is the plugin that knows how to talk to one API
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73" # any 6.x from 6.73 up, but never 7.0 (a new major version may break things)
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9" # used for a random suffix in the bucket name
    }
  }
}
