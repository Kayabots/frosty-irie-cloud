# ---------------------------------------------------------------------------
# AWS Config: runtime (post-deployment) policy checks, defined in
# policies/aws/config-rules.json. Optional because Config is not free tier.
# Vanta and Security Hub both read these rule results as evidence.
# ---------------------------------------------------------------------------
locals {
  config_rules = { for r in jsondecode(file("${path.module}/../../../policies/aws/config-rules.json")).rules : r.name => r }
}

resource "aws_s3_bucket" "config" {
  #checkov:skip=CKV_AWS_18:Config delivery bucket; API access captured by CloudTrail
  count  = var.enable_aws_config ? 1 : 0
  bucket = "frostyirie-config-${local.account_id}"
}

resource "aws_s3_bucket_versioning" "config" {
  count  = var.enable_aws_config ? 1 : 0
  bucket = aws_s3_bucket.config[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "config" {
  count  = var.enable_aws_config ? 1 : 0
  bucket = aws_s3_bucket.config[0].id
  rule {
    id     = "retain-1y"
    status = "Enabled"
    filter {}
    expiration {
      days = 365
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  count                   = var.enable_aws_config ? 1 : 0
  bucket                  = aws_s3_bucket.config[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_service_linked_role" "config" {
  count            = var.enable_aws_config ? 1 : 0
  aws_service_name = "config.amazonaws.com"
}

resource "aws_s3_bucket_policy" "config" {
  count  = var.enable_aws_config ? 1 : 0
  bucket = aws_s3_bucket.config[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSConfigBucketPermissionsCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource  = aws_s3_bucket.config[0].arn
      },
      {
        Sid       = "AWSConfigBucketDelivery"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.config[0].arn}/AWSLogs/${local.account_id}/Config/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      },
    ]
  })
}

resource "aws_config_configuration_recorder" "main" {
  count    = var.enable_aws_config ? 1 : 0
  name     = "frostyirie"
  role_arn = aws_iam_service_linked_role.config[0].arn
  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
  recording_mode {
    recording_frequency = "DAILY" # cheaper than continuous, enough for a small workload
  }
}

resource "aws_config_delivery_channel" "main" {
  count          = var.enable_aws_config ? 1 : 0
  name           = "frostyirie"
  s3_bucket_name = aws_s3_bucket.config[0].bucket
  depends_on     = [aws_config_configuration_recorder.main, aws_s3_bucket_policy.config]
}

resource "aws_config_configuration_recorder_status" "main" {
  count      = var.enable_aws_config ? 1 : 0
  name       = aws_config_configuration_recorder.main[0].name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

resource "aws_config_config_rule" "managed" {
  for_each = { for k, v in local.config_rules : k => v if var.enable_aws_config }
  name     = each.key

  source {
    owner             = "AWS"
    source_identifier = each.value.identifier
  }

  input_parameters = try(jsonencode(each.value.params), null)
  tags             = { Controls = join(" / ", each.value.controls) }
  depends_on       = [aws_config_configuration_recorder_status.main]
}
