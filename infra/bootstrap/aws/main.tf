terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
  # Bootstrap keeps local state on first run. After apply, migrate it into the
  # bucket it created:  terraform init -migrate-state -backend-config=backend.hcl
  # (uncomment the block below first).
  backend "s3" {}
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project            = "frostyirie"
      Environment        = "shared"
      ManagedBy          = "terraform"
      Layer              = "bootstrap-governance"
      DataClassification = "internal"
      VantaOwner         = var.owner_email
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "owner_email" {
  type = string
}

variable "github_repository" {
  description = "owner/repo allowed to assume the CI roles through GitHub OIDC."
  type        = string
}

variable "vanta_account_id" {
  description = "AWS account ID that Vanta shows on its AWS connection page. Empty skips the Vanta role."
  type        = string
  default     = ""
}

variable "vanta_external_id" {
  description = "External ID shown on the Vanta AWS connection page."
  type        = string
  default     = ""
  sensitive   = true
}

variable "enable_aws_config" {
  description = "AWS Config recorder + managed rules (roughly $1–3/month at this size; not free tier)."
  type        = bool
  default     = false
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}
