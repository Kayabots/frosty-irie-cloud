data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name       = "${var.project}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id

  # Tags drive three things: cost allocation, AWS Backup selection, and Vanta
  # resource inventory (Vanta reads the Vanta* tags to assign owners and
  # flag which resources hold customer data).
  tags = {
    Project            = var.project
    Environment        = var.environment
    ManagedBy          = "terraform"
    Repository         = "frosty-irie-cloud"
    Role               = "primary"
    DataClassification = "internal"
    Compliance         = "NIST-CSF/ISO27001/SOC2/SOX/GDPR"
    VantaOwner         = var.owner_email
    VantaNonProd       = var.environment == "prod" ? "false" : "true"
  }

  web_origins = compact([
    "https://${aws_cloudfront_distribution.web.domain_name}",
    var.standby_web_origin,
  ])
}
