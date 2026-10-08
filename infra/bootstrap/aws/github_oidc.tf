# ---------------------------------------------------------------------------
# GitHub Actions -> AWS with OIDC (no long-lived access keys anywhere)
#   frostyirie-gh-plan    : pull requests, read-only + state access
#   frostyirie-gh-deploy  : "prod" GitHub Environment only (requires approval)
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"] # ignored by AWS for this provider, kept for older providers
}

data "aws_iam_policy_document" "gh_plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${local.gh_sub_repo}:pull_request",
        "repo:${local.gh_sub_repo}:ref:refs/heads/main",
      ]
    }
  }
}

data "aws_iam_policy_document" "gh_deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.gh_sub_repo}:environment:prod"]
    }
  }
}

data "aws_iam_policy_document" "state_access" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

resource "aws_iam_role" "gh_plan" {
  name                 = "frostyirie-gh-plan"
  assume_role_policy   = data.aws_iam_policy_document.gh_plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "gh_plan_ro" {
  role       = aws_iam_role.gh_plan.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "gh_plan_extra" {
  name = "state-and-pii-guard"
  role = aws_iam_role.gh_plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(jsondecode(data.aws_iam_policy_document.state_access.json).Statement, [{
      Sid      = "NoCustomerDataReadsFromPullRequests"
      Effect   = "Deny"
      Action   = ["dynamodb:GetItem", "dynamodb:BatchGetItem", "dynamodb:Query", "dynamodb:Scan", "dynamodb:ExportTableToPointInTime"]
      Resource = "arn:${data.aws_partition.current.partition}:dynamodb:*:${local.account_id}:table/frostyirie-*"
    }])
  })
}

resource "aws_iam_role" "gh_deploy" {
  name                 = "frostyirie-gh-deploy"
  assume_role_policy   = data.aws_iam_policy_document.gh_deploy_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "gh_deploy_power" {
  role       = aws_iam_role.gh_deploy.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/PowerUserAccess"
}

# PowerUser has no IAM. Allow IAM only for workload roles named frostyirie-*,
# and never for the CI roles themselves (no privilege escalation).
resource "aws_iam_role_policy" "gh_deploy_iam" {
  name = "scoped-iam-and-state"
  role = aws_iam_role.gh_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(jsondecode(data.aws_iam_policy_document.state_access.json).Statement, [
      {
        Sid    = "WorkloadRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:TagRole", "iam:UntagRole",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole", "iam:PassRole", "iam:UpdateAssumeRolePolicy",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:role/frostyirie-*"
      },
      {
        Sid    = "ProtectCiRoles"
        Effect = "Deny"
        Action = ["iam:*"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:role/frostyirie-gh-*",
          "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:role/frostyirie-vanta-*",
        ]
      },
      {
        Sid      = "NoTrailTampering"
        Effect   = "Deny"
        Action   = ["cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail"]
        Resource = "*"
      },
    ])
  })
}

output "gh_plan_role_arn" {
  value = aws_iam_role.gh_plan.arn
}

output "gh_deploy_role_arn" {
  value = aws_iam_role.gh_deploy.arn
}
