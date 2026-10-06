variable "region" {
  description = "Primary AWS region. us-east-1 keeps CloudFront, ACM and the workload together."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "project" {
  description = "Short project slug used in resource names."
  type        = string
  default     = "frostyirie"
}

variable "owner_email" {
  description = "Accountable owner (Vanta resource owner, budget and alarm notifications)."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Alert threshold for the AWS Budgets guardrail. Free tier target is $0."
  type        = number
  default     = 5
}

variable "standby_web_host" {
  description = "Azure Storage static website host (no scheme), used as CloudFront failover origin. Empty disables the origin group."
  type        = string
  default     = ""
}

variable "standby_web_origin" {
  description = "Full https origin of the Azure standby site, allowed by API CORS."
  type        = string
  default     = ""
}

variable "enable_backup_plan" {
  description = "AWS Backup daily plan for DynamoDB (small storage cost; PITR is always on)."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention."
  type        = number
  default     = 30
}
