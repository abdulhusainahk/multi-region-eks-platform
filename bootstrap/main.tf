###############################################################################
# Bootstrap — Terraform remote state backend resources
#
# Run this ONCE per environment before any other Terraform.
# Creates:
#   - S3 bucket for state files (versioning + SSE + public-access block)
#   - DynamoDB table for state locking
#   - KMS key for state encryption
#
# Usage:
#   terraform init  (uses local backend initially)
#   terraform apply -var="environment=dev" -var="region=us-east-1"
###############################################################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
  # Bootstrap uses LOCAL backend — do not add an S3 backend here!
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name    = "clevertap-terraform-state-${var.environment}"
  kms_alias_name = "alias/clevertap-terraform-state-${var.environment}"
  table_name     = "clevertap-terraform-locks-${var.environment}"

  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform-bootstrap"
    Project     = "clevertap"
  }
}

###############################################################################
# KMS Key for state encryption
###############################################################################

resource "aws_kms_key" "state" {
  description             = "Terraform state encryption key — ${var.environment}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = merge(local.common_tags, { Name = local.kms_alias_name })
}

resource "aws_kms_alias" "state" {
  name          = local.kms_alias_name
  target_key_id = aws_kms_key.state.key_id
}

###############################################################################
# S3 Bucket — Terraform state storage
###############################################################################

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  # Prevent accidental deletion of state
  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = local.bucket_name })
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyNonTLS"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action    = "s3:*"
        Resource  = ["${aws_s3_bucket.state.arn}", "${aws_s3_bucket.state.arn}/*"]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      {
        Sid       = "DenyNonEncryptedUploads"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.state.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = "aws:kms"
          }
        }
      }
    ]
  })
}

###############################################################################
# DynamoDB — State locking
###############################################################################

resource "aws_dynamodb_table" "state_lock" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.state.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.common_tags, { Name = local.table_name })
}

###############################################################################
# Outputs
###############################################################################

output "state_bucket_name" { value = aws_s3_bucket.state.id }
output "state_bucket_arn" { value = aws_s3_bucket.state.arn }
output "lock_table_name" { value = aws_dynamodb_table.state_lock.name }
output "kms_key_arn" { value = aws_kms_key.state.arn }
output "kms_key_alias" { value = aws_kms_alias.state.name }
