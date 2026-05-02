# =============================================================================
# FILE: config/terraform/variables.tf
# PURPOSE: Input variables for the Snowflake Iceberg infrastructure Terraform.
#
# HOW TO SET VALUES:
#   Option 1 (recommended): terraform.tfvars file (never commit to git)
#   Option 2: Environment variables: TF_VAR_snowflake_iam_user_arn=...
#   Option 3: -var flag at apply time
#
# SENSITIVE VARIABLES: snowflake_iam_user_arn, snowflake_external_id
#   These are retrieved from Snowflake after the first CREATE EXTERNAL VOLUME.
#   See sql/01_setup_external_volume.sql STEP 4.
# =============================================================================

# =============================================================================
# REQUIRED VARIABLES (no defaults — must be explicitly set)
# =============================================================================

variable "project_name" {
  description = "Project identifier used as prefix for all resource names (e.g., 'tradeco'). Must be lowercase, no spaces."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric and hyphens only."
  }
}

variable "snowflake_iam_user_arn" {
  description = <<-EOF
    Snowflake's IAM User ARN — retrieved from:
      DESCRIBE EXTERNAL VOLUME iceberg_prod_vol;
    Look for the STORAGE_AWS_IAM_USER_ARN property.
    Example: arn:aws:iam::123456789999:user/snowflake-iam-user-abc123
    Set this AFTER first running sql/01_setup_external_volume.sql.
    Leave as placeholder for Step 1 Terraform apply (bucket creation only).
  EOF
  type        = string
  default     = "PLACEHOLDER_RUN_DESCRIBE_EXTERNAL_VOLUME_FIRST"

  validation {
    condition     = can(regex("^arn:aws:iam::", var.snowflake_iam_user_arn)) || var.snowflake_iam_user_arn == "PLACEHOLDER_RUN_DESCRIBE_EXTERNAL_VOLUME_FIRST"
    error_message = "snowflake_iam_user_arn must be a valid IAM ARN starting with 'arn:aws:iam::' or the placeholder value."
  }
}

variable "snowflake_external_id" {
  description = <<-EOF
    Snowflake's External ID for STS AssumeRole trust — retrieved from:
      DESCRIBE EXTERNAL VOLUME iceberg_prod_vol;
    Look for the STORAGE_AWS_EXTERNAL_ID property.
    Example: ABCXYZ_SFCRole=2_abc123/xyz456
    This value must match EXACTLY. A single character mismatch = silent auth failure.
  EOF
  type        = string
  default     = "PLACEHOLDER_RUN_DESCRIBE_EXTERNAL_VOLUME_FIRST"
}

# =============================================================================
# VARIABLES WITH DEFAULTS (override via terraform.tfvars if needed)
# =============================================================================

variable "primary_region" {
  description = "AWS region for the primary S3 Iceberg bucket and IAM role."
  type        = string
  default     = "us-east-1"
}

variable "dr_region" {
  description = "AWS region for the disaster recovery S3 bucket (Cross-Region Replication destination)."
  type        = string
  default     = "us-west-2"
}

variable "environment" {
  description = "Deployment environment tag. Used for resource tagging and naming."
  type        = string
  default     = "production"

  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "environment must be one of: development, staging, production."
  }
}

variable "kms_deletion_window_days" {
  description = "KMS key deletion window in days. Minimum 7, maximum 30. Set to 30 for production to allow recovery window."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days must be between 7 and 30."
  }
}

variable "warm_tier_intelligent_tiering_days" {
  description = "Days after which warm tier S3 objects transition to Intelligent-Tiering storage class."
  type        = number
  default     = 90
}

variable "cold_tier_ia_transition_days" {
  description = "Days after which cold tier S3 objects transition to Standard-IA storage class."
  type        = number
  default     = 30
}

variable "cold_tier_glacier_ir_transition_days" {
  description = "Days after which cold tier S3 objects transition to Glacier Instant Retrieval."
  type        = number
  default     = 90
}

variable "iceberg_metadata_expiry_days" {
  description = "Days after which old Iceberg metadata snapshot files expire and are deleted from S3. Set based on compliance data retention requirements."
  type        = number
  default     = 365
}

variable "enable_crr" {
  description = "Enable S3 Cross-Region Replication to DR bucket. Set to false for non-production environments to reduce cost."
  type        = bool
  default     = true
}

variable "dr_storage_class" {
  description = "S3 storage class for replicated DR objects. STANDARD_IA is appropriate for DR data that is rarely accessed."
  type        = string
  default     = "STANDARD_IA"

  validation {
    condition     = contains(["STANDARD", "STANDARD_IA", "ONEZONE_IA", "GLACIER_IR"], var.dr_storage_class)
    error_message = "dr_storage_class must be a valid S3 storage class."
  }
}

variable "additional_tags" {
  description = "Additional tags to apply to all resources. Merged with common_tags."
  type        = map(string)
  default     = {}
}
