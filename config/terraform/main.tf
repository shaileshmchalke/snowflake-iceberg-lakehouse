# =============================================================================
# FILE: config/terraform/main.tf
# PURPOSE: Provisions AWS infrastructure for Snowflake Iceberg external volume.
#          Creates: S3 buckets (primary + DR), IAM role with trust policy,
#          KMS keys (primary + DR), S3 CRR with KMS encryption,
#          bucket lifecycle rules, DR bucket policy.
#
# FIXES APPLIED (vs original):
#   Fix 5a — DR KMS key added (encrypted CRR requires KMS in DR region)
#   Fix 5b — DR bucket encryption configuration added
#   Fix 5c — DR bucket policy added (allows CRR from primary account)
#   Fix 5d — CRR configuration updated to use DR KMS key + SSE criteria
#   Fix 6  — prevent_destroy lifecycle added to primary bucket
#
# DEPLOYMENT ORDER:
#   Step 1: terraform init && terraform apply -target=aws_s3_bucket.iceberg_primary
#   Step 2: Run sql/01_setup_external_volume.sql, get Snowflake IAM principal
#   Step 3: Set var.snowflake_iam_user_arn and var.snowflake_external_id
#   Step 4: terraform apply  (applies trust policy + remaining resources)
#
# ACCOUNT NOTE: IAM role must be in the SAME account as S3 bucket.
#               See docs/lessons-learned.md Failure 3 for details.
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "company-terraform-state"
    key    = "snowflake-iceberg/terraform.tfstate"
    region = "us-east-1"
  }
}

# Data account provider (where S3 and IAM role live)
provider "aws" {
  alias  = "data_account"
  region = var.primary_region
  # Profile or role assumption configured via environment
}

# DR account provider
provider "aws" {
  alias  = "dr_account"
  region = var.dr_region
}

# =============================================================================
# DATA SOURCES
# =============================================================================

data "aws_caller_identity" "current" {
  provider = aws.data_account
}

data "aws_region" "current" {
  provider = aws.data_account
}

# =============================================================================
# KMS KEY — PRIMARY REGION (us-east-1)
# =============================================================================

resource "aws_kms_key" "iceberg_kms" {
  provider                = aws.data_account
  description             = "KMS key for Snowflake Iceberg S3 bucket encryption"
  deletion_window_in_days = var.kms_deletion_window_days
  enable_key_rotation     = true
  tags                    = local.common_tags
}

resource "aws_kms_alias" "iceberg_kms_alias" {
  provider      = aws.data_account
  name          = "alias/${var.project_name}-iceberg"
  target_key_id = aws_kms_key.iceberg_kms.key_id
}

# =============================================================================
# KMS KEY — DR REGION (us-west-2)
# FIX 5a: DR region KMS key is required for encrypted object replication.
# Without this, S3 CRR cannot re-encrypt objects in the DR bucket.
# =============================================================================

resource "aws_kms_key" "iceberg_kms_dr" {
  provider                = aws.dr_account
  description             = "KMS key for Snowflake Iceberg DR S3 bucket encryption"
  deletion_window_in_days = var.kms_deletion_window_days
  enable_key_rotation     = true
  tags                    = local.common_tags
}

resource "aws_kms_alias" "iceberg_kms_dr_alias" {
  provider      = aws.dr_account
  name          = "alias/${var.project_name}-iceberg-dr"
  target_key_id = aws_kms_key.iceberg_kms_dr.key_id
}

# =============================================================================
# S3 BUCKET — PRIMARY (us-east-1)
# =============================================================================

resource "aws_s3_bucket" "iceberg_primary" {
  provider = aws.data_account
  bucket   = "${var.project_name}-iceberg-prod"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-iceberg-prod"
  })

  # FIX 6: prevent_destroy stops accidental terraform destroy on production bucket.
  # To intentionally delete: comment this block, run terraform apply, then destroy.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "iceberg_primary" {
  provider = aws.data_account
  bucket   = aws_s3_bucket.iceberg_primary.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "iceberg_primary" {
  provider = aws.data_account
  bucket   = aws_s3_bucket.iceberg_primary.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.iceberg_kms.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "iceberg_primary" {
  provider = aws.data_account
  bucket   = aws_s3_bucket.iceberg_primary.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 Lifecycle rules — primary bucket
resource "aws_s3_bucket_lifecycle_configuration" "iceberg_primary" {
  provider = aws.data_account
  bucket   = aws_s3_bucket.iceberg_primary.id

  # Warm tier: Intelligent-Tiering after 90 days
  rule {
    id     = "trades-warm-tiering"
    status = "Enabled"

    filter {
      prefix = "trades_warm/"
    }

    transition {
      days          = 90
      storage_class = "INTELLIGENT_TIERING"
    }
  }

  # Cold tier: Standard-IA after 30 days, Glacier IR after 90 days
  rule {
    id     = "trades-cold-tiering"
    status = "Enabled"

    filter {
      prefix = "trades_cold/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
  }

  # Iceberg metadata cleanup — expire old metadata snapshots after 1 year
  rule {
    id     = "iceberg-metadata-expiry"
    status = "Enabled"

    filter {
      and {
        prefix = "trades_cold/metadata/"
        tags = {
          iceberg-metadata = "true"
        }
      }
    }

    expiration {
      days = 365
    }
  }
}

# =============================================================================
# S3 BUCKET — DR (us-west-2)
# =============================================================================

resource "aws_s3_bucket" "iceberg_dr" {
  provider = aws.dr_account
  bucket   = "${var.project_name}-iceberg-dr"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-iceberg-dr"
  })
}

resource "aws_s3_bucket_versioning" "iceberg_dr" {
  provider = aws.dr_account
  bucket   = aws_s3_bucket.iceberg_dr.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "iceberg_dr" {
  provider = aws.dr_account
  bucket   = aws_s3_bucket.iceberg_dr.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# FIX 5b: DR bucket encryption using the DR-region KMS key.
# Original file had NO encryption on the DR bucket — encrypted objects
# from primary would fail to replicate without a matching KMS key in DR region.
resource "aws_s3_bucket_server_side_encryption_configuration" "iceberg_dr" {
  provider = aws.dr_account
  bucket   = aws_s3_bucket.iceberg_dr.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.iceberg_kms_dr.arn
    }
    bucket_key_enabled = true
  }
}

# FIX 5c: DR bucket policy — explicitly allows the CRR IAM role to write
# replicated objects. Without this policy, CRR fails with AccessDenied
# even though the IAM role policy allows s3:ReplicateObject.
resource "aws_s3_bucket_policy" "iceberg_dr_replication_policy" {
  provider = aws.dr_account
  bucket   = aws_s3_bucket.iceberg_dr.id

  # depends_on ensures bucket exists and versioning is enabled before policy applies
  depends_on = [aws_s3_bucket_versioning.iceberg_dr]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCrossAccountReplication"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.s3_crr_role.arn
        }
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags",
          "s3:ObjectOwnerOverrideToBucketOwner"
        ]
        Resource = "${aws_s3_bucket.iceberg_dr.arn}/*"
      },
      {
        Sid    = "AllowCRRBucketLevelAccess"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.s3_crr_role.arn
        }
        Action = [
          "s3:GetBucketVersioning",
          "s3:PutBucketVersioning"
        ]
        Resource = aws_s3_bucket.iceberg_dr.arn
      }
    ]
  })
}

# =============================================================================
# IAM ROLE — for Snowflake external volume access
# CRITICAL: This role must be in the SAME account as the S3 bucket.
#           See docs/lessons-learned.md Failure 3.
# =============================================================================

resource "aws_iam_role" "snowflake_iceberg_role" {
  provider = aws.data_account
  name     = "snowflake-iceberg-role"

  # Trust policy allows Snowflake's IAM user to assume this role.
  # snowflake_iam_user_arn and snowflake_external_id are retrieved from:
  #   DESCRIBE EXTERNAL VOLUME iceberg_prod_vol;
  # in Snowflake after the first CREATE EXTERNAL VOLUME.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = var.snowflake_iam_user_arn
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = var.snowflake_external_id
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

# IAM policy — S3 and KMS permissions for Snowflake Iceberg
resource "aws_iam_role_policy" "snowflake_s3_policy" {
  provider = aws.data_account
  name     = "snowflake-iceberg-s3-access"
  role     = aws_iam_role.snowflake_iceberg_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SnowflakeIcebergS3Access"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:DeleteObjectVersion",
          "s3:ListBucket",
          "s3:ListBucketVersions",
          "s3:GetBucketLocation",
          "s3:GetBucketVersioning",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = [
          aws_s3_bucket.iceberg_primary.arn,
          "${aws_s3_bucket.iceberg_primary.arn}/*"
        ]
      },
      {
        Sid    = "SnowflakeKMSAccess"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = [
          aws_kms_key.iceberg_kms.arn
        ]
      }
    ]
  })
}

# =============================================================================
# IAM ROLE — S3 Cross-Region Replication
# =============================================================================

resource "aws_iam_role" "s3_crr_role" {
  provider = aws.data_account
  name     = "s3-crr-iceberg-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "s3_crr_policy" {
  provider = aws.data_account
  name     = "s3-crr-iceberg-policy"
  role     = aws_iam_role.s3_crr_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowReadSourceBucket"
        Effect   = "Allow"
        Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Resource = [aws_s3_bucket.iceberg_primary.arn]
      },
      {
        Sid    = "AllowReadSourceObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ]
        Resource = ["${aws_s3_bucket.iceberg_primary.arn}/*"]
      },
      {
        Sid    = "AllowWriteDestinationBucket"
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags"
        ]
        Resource = ["${aws_s3_bucket.iceberg_dr.arn}/*"]
      },
      {
        Sid    = "AllowKMSDecryptSource"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = [aws_kms_key.iceberg_kms.arn]
      },
      {
        Sid    = "AllowKMSEncryptDestination"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:GenerateDataKey"
        ]
        Resource = [aws_kms_key.iceberg_kms_dr.arn]
      }
    ]
  })
}

# FIX 5d: CRR configuration updated with:
#   1. DR KMS key for replica encryption
#   2. sse_kms_encrypted_objects criteria (required when source is KMS-encrypted)
#   3. depends_on includes DR bucket policy (CRR must not start before policy exists)
# REPLACES the original aws_s3_bucket_replication_configuration resource.
resource "aws_s3_bucket_replication_configuration" "iceberg_crr" {
  provider = aws.data_account
  depends_on = [
    aws_s3_bucket_versioning.iceberg_primary,
    aws_s3_bucket_versioning.iceberg_dr,
    aws_s3_bucket_policy.iceberg_dr_replication_policy
  ]

  role   = aws_iam_role.s3_crr_role.arn
  bucket = aws_s3_bucket.iceberg_primary.id

  rule {
    id     = "full-bucket-encrypted-replication"
    status = "Enabled"

    source_selection_criteria {
      sse_kms_encrypted_objects {
        # Only replicate KMS-encrypted objects.
        # Without this, CRR silently skips encrypted objects.
        status = "Enabled"
      }
    }

    destination {
      bucket        = aws_s3_bucket.iceberg_dr.arn
      storage_class = var.dr_storage_class

      encryption_configuration {
        # Re-encrypt replicated objects using the DR region KMS key.
        # Without this, encrypted objects cannot be written to DR bucket.
        replica_kms_key_id = aws_kms_key.iceberg_kms_dr.arn
      }
    }
  }
}

# =============================================================================
# LOCALS
# =============================================================================

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "data-platform"
    CostCenter  = "data-infrastructure"
  }
}

# =============================================================================
# OUTPUTS
# =============================================================================

output "primary_bucket_name" {
  description = "S3 primary Iceberg bucket name — use in Snowflake external volume DDL"
  value       = aws_s3_bucket.iceberg_primary.bucket
}

output "primary_bucket_arn" {
  description = "ARN of primary S3 bucket"
  value       = aws_s3_bucket.iceberg_primary.arn
}

output "dr_bucket_name" {
  description = "S3 DR Iceberg bucket name"
  value       = aws_s3_bucket.iceberg_dr.bucket
}

output "snowflake_iam_role_arn" {
  description = "IAM role ARN — use in sql/01_setup_external_volume.sql"
  value       = aws_iam_role.snowflake_iceberg_role.arn
}

output "primary_kms_key_arn" {
  description = "KMS key ARN for primary bucket encryption"
  value       = aws_kms_key.iceberg_kms.arn
}

output "dr_kms_key_arn" {
  description = "KMS key ARN for DR bucket encryption"
  value       = aws_kms_key.iceberg_kms_dr.arn
}

output "next_steps" {
  description = "Instructions after first terraform apply"
  value       = "1. Run sql/01_setup_external_volume.sql in Snowflake. 2. Run DESCRIBE EXTERNAL VOLUME iceberg_prod_vol. 3. Copy STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID. 4. Set as var.snowflake_iam_user_arn and var.snowflake_external_id. 5. Run terraform apply again to update trust policy."
}
