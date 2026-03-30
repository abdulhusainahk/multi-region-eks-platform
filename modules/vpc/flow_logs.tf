###############################################################################
# VPC Flow Logs → S3
###############################################################################

locals {
  # Allow callers to BYO bucket or let the module create one
  flow_logs_bucket_name = (
    var.flow_logs_s3_bucket_name != ""
    ? var.flow_logs_s3_bucket_name
    : "${local.name}-vpc-flow-logs-${data.aws_caller_identity.current.account_id}"
  )

  create_flow_logs_bucket = var.enable_flow_logs && var.flow_logs_s3_bucket_name == ""
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# S3 Bucket for Flow Logs
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "flow_logs" {
  count = local.create_flow_logs_bucket ? 1 : 0

  bucket        = local.flow_logs_bucket_name
  force_destroy = false

  tags = merge(local.common_tags, { Name = "${local.name}-vpc-flow-logs" })
}

resource "aws_s3_bucket_versioning" "flow_logs" {
  count = local.create_flow_logs_bucket ? 1 : 0

  bucket = aws_s3_bucket.flow_logs[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flow_logs" {
  count = local.create_flow_logs_bucket ? 1 : 0

  bucket = aws_s3_bucket.flow_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "flow_logs" {
  count = local.create_flow_logs_bucket ? 1 : 0

  bucket = aws_s3_bucket.flow_logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle: Hot → Standard-IA → Glacier Instant Retrieval → Expire
resource "aws_s3_bucket_lifecycle_configuration" "flow_logs" {
  count = local.create_flow_logs_bucket ? 1 : 0

  bucket = aws_s3_bucket.flow_logs[0].id

  rule {
    id     = "flow-logs-lifecycle"
    status = "Enabled"

    transition {
      days          = var.flow_logs_retention_days
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = var.flow_logs_glacier_days
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = var.flow_logs_expiration_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# Bucket policy: only allow delivery from the VPC Flow Logs service
resource "aws_s3_bucket_policy" "flow_logs" {
  count = local.create_flow_logs_bucket ? 1 : 0

  bucket = aws_s3_bucket.flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSLogDeliveryWrite"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.flow_logs[0].arn}/AWSLogs/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "AWSLogDeliveryAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.flow_logs[0].arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid       = "DenyNonTLS"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.flow_logs[0].arn,
          "${aws_s3_bucket.flow_logs[0].arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# VPC Flow Log resource
# ---------------------------------------------------------------------------

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id       = aws_vpc.this.id
  traffic_type = "ALL"
  iam_role_arn = null # not needed for S3 delivery
  log_destination = (
    local.create_flow_logs_bucket
    ? "${aws_s3_bucket.flow_logs[0].arn}/vpc-flow-logs/"
    : "arn:aws:s3:::${local.flow_logs_bucket_name}/vpc-flow-logs/"
  )
  log_destination_type = "s3"

  # Parquet + Hive-compatible partitioning enables efficient Athena queries
  destination_options {
    file_format                = "parquet"
    hive_compatible_partitions = true
    per_hour_partition         = true
  }

  tags = merge(local.common_tags, { Name = "${local.name}-flow-log" })
}
