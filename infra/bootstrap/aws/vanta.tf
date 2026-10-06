# ---------------------------------------------------------------------------
# Vanta continuous monitoring: read-only cross-account role.
# Copy the account ID and external ID from Vanta > Integrations > AWS.
# Vanta's setup page lists the exact policy it wants; SecurityAudit + the
# small read-only addendum below is the usual shape. Re-check it when you connect.
# ---------------------------------------------------------------------------
locals {
  vanta_enabled = var.vanta_account_id != "" && var.vanta_external_id != ""
}

data "aws_iam_policy_document" "vanta_trust" {
  count = local.vanta_enabled ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${var.vanta_account_id}:root"]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.vanta_external_id]
    }
  }
}

resource "aws_iam_role" "vanta" {
  count              = local.vanta_enabled ? 1 : 0
  name               = "frostyirie-vanta-auditor"
  assume_role_policy = data.aws_iam_policy_document.vanta_trust[0].json
  tags               = { VantaDescription = "Read-only role assumed by Vanta for continuous compliance monitoring" }
}

resource "aws_iam_role_policy_attachment" "vanta_security_audit" {
  count      = local.vanta_enabled ? 1 : 0
  role       = aws_iam_role.vanta[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/SecurityAudit"
}

resource "aws_iam_role_policy" "vanta_addendum" {
  #checkov:skip=CKV_AWS_355:List/Describe/View actions here do not support resource-level scoping; the Deny statement is intentionally account-wide
  count = local.vanta_enabled ? 1 : 0
  name  = "vanta-read-addendum"
  role  = aws_iam_role.vanta[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyDataPlaneReads"
        Effect   = "Deny"
        Action   = ["dynamodb:GetItem", "dynamodb:BatchGetItem", "dynamodb:Query", "dynamodb:Scan", "s3:GetObject"]
        Resource = "*"
      },
      {
        Sid      = "ReadCostAndBackupPosture"
        Effect   = "Allow"
        Action   = ["backup:List*", "backup:Describe*", "budgets:ViewBudget", "support:DescribeTrustedAdvisorChecks"]
        Resource = "*"
      },
    ]
  })
}

output "vanta_role_arn" {
  value = try(aws_iam_role.vanta[0].arn, "not created: set vanta_account_id and vanta_external_id")
}
