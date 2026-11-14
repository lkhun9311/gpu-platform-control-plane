terraform {
  # 1.10 is the floor because that is where the S3 backend learned to lock on a state-adjacent object
  # (use_lockfile) instead of a DynamoDB table. Everything below that line needs the table back.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.region
  # Refuses to plan or apply with credentials for any other account (r5 finding 8, proposal P3): a profile name is not an
  # account, and environment credentials outrank it.
  allowed_account_ids = var.allowed_account_ids
}
