variable "location" {
  description = "Azure region for the standby stack. East US 2 keeps latency to Costa Rica low."
  type        = string
  default     = "eastus2"
}

variable "environment" {
  type    = string
  default = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "project" {
  type    = string
  default = "frostyirie"
}

variable "owner_email" {
  description = "Accountable owner (tags, budget and alert notifications)."
  type        = string
}

variable "primary_web_origin" {
  description = "https origin of the AWS CloudFront site, allowed by Function CORS."
  type        = string
  default     = ""
}

variable "cosmos_free_tier" {
  description = "Only one free-tier Cosmos DB account is allowed per subscription."
  type        = bool
  default     = true
}

variable "monthly_budget_usd" {
  type    = number
  default = 5
}

variable "deployer_object_id" {
  description = "Object ID of the GitHub Actions service principal. Gets Cosmos data access for the DR sync job."
  type        = string
  default     = ""
}
