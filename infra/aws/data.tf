# ---------------------------------------------------------------------------
# Order data: two DynamoDB tables, split by retention
#   orders   -> financial record (no direct personal data), kept for audit
#   contacts -> name / phone / address, auto-deleted by TTL after 30 days
# Both are always-free provisioned capacity (5 RCU / 5 WCU each).
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "orders" {
  #checkov:skip=CKV2_AWS_16:Fixed capacity keeps both tables inside the 25 RCU/WCU always-free pool (EXC-009)
  name                        = "${local.name}-orders"
  billing_mode                = "PROVISIONED"
  read_capacity               = 5
  write_capacity              = 5
  hash_key                    = "orderId"
  deletion_protection_enabled = true

  attribute {
    name = "orderId"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true # continuous backups, 35-day restore window
  }

  server_side_encryption {
    enabled = true # AWS managed key (alias/aws/dynamodb)
  }

  tags = {
    Backup                = "daily"
    DataClassification    = "confidential"
    VantaDescription      = "Order ledger with items and taxes and totals - pseudonymous customer key only"
    VantaContainsUserData = "false"
    VantaContainsEPHI     = "false"
    RetentionPolicy       = "7y-financial"
  }
}

resource "aws_dynamodb_table" "contacts" {
  #checkov:skip=CKV2_AWS_16:Fixed capacity keeps both tables inside the 25 RCU/WCU always-free pool (EXC-009)
  name                        = "${local.name}-order-contacts"
  billing_mode                = "PROVISIONED"
  read_capacity               = 5
  write_capacity              = 5
  hash_key                    = "orderId"
  deletion_protection_enabled = true

  attribute {
    name = "orderId"
    type = "S"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Backup                = "daily"
    DataClassification    = "restricted-pii"
    VantaDescription      = "Customer contact details for order fulfilment - TTL 30 days"
    VantaContainsUserData = "true"
    VantaUserDataStored   = "name / phone number / delivery address or beach spot"
    RetentionPolicy       = "30d-ttl"
  }
}
