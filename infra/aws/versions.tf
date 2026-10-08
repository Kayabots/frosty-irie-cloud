terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.67"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  # Partial config: values come from backend.hcl (see backend.hcl.example),
  # created once by infra/bootstrap/aws. S3-native locking, no DynamoDB lock table.
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}
