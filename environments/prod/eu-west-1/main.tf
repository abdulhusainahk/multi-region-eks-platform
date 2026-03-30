###############################################################################
# Production — eu-west-1 (Ireland)
#
# DATA RESIDENCY REQUIREMENTS:
#   - EU customer data must NEVER leave eu-west-1
#   - This cluster is fully isolated: no TGW to non-EU regions
#   - IAM SCPs enforce eu-west-1 boundary at the AWS account level
#   - Separate AWS account (clevertap-prod-eu) with SCP guardrails
#
# See docs/eu-data-residency.md for the full architecture design.
###############################################################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  # Explicit allowed_account_ids enforces this config only runs in the EU account
  allowed_account_ids = [var.eu_aws_account_id]

  default_tags {
    tags = {
      Environment        = "prod"
      ManagedBy          = "terraform"
      Project            = "clevertap"
      Owner              = "platform-engineering"
      DataResidency      = "EU"
      DataClassification = "EU-GDPR"
      CostCenter         = "infrastructure"
    }
  }
}

###############################################################################
# VPC — isolated, no TGW to non-EU regions
###############################################################################

module "vpc" {
  source = "../../../modules/vpc"

  name        = "clevertap"
  environment = "prod"
  region      = var.region
  vpc_cidr    = var.vpc_cidr
  azs         = var.azs

  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  intra_subnet_cidrs   = var.intra_subnet_cidrs

  enable_nat_gateway = true
  single_nat_gateway = false

  # NO transit_gateway_id — EU VPC is intentionally isolated from other regions
  # to enforce data residency. Cross-region connectivity is explicitly blocked.

  enable_flow_logs          = true
  flow_logs_retention_days  = 90
  flow_logs_glacier_days    = 180
  flow_logs_expiration_days = 365 # GDPR: retain logs for audit purposes
}

###############################################################################
# EU-specific KMS key for S3 flow logs (key stays in eu-west-1)
###############################################################################

resource "aws_kms_key" "flow_logs_eu" {
  description             = "KMS key for EU VPC flow logs - eu-west-1 only"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  # Key policy: deny any operation that would replicate data outside eu-west-1
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.eu_aws_account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid       = "DenyKeyUseOutsideEU"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action    = "kms:*"
        Resource  = "*"
        Condition = {
          StringNotEquals = {
            "aws:RequestedRegion" = "eu-west-1"
          }
        }
      }
    ]
  })

  tags = {
    Name          = "clevertap-prod-eu-flow-logs-key"
    DataResidency = "EU"
  }
}

###############################################################################
# EKS Cluster
###############################################################################

module "eks" {
  source = "../../../modules/eks"

  cluster_name       = "clevertap-prod-euw1"
  environment        = "prod"
  region             = var.region
  kubernetes_version = var.kubernetes_version

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = false

  cloudwatch_log_retention_days = 90

  node_groups = {
    on-demand-critical = {
      instance_types       = ["m6i.2xlarge", "m6a.2xlarge", "m5.2xlarge"]
      on_demand_base_count = 3
      on_demand_percentage = 100
      desired_size         = 6
      min_size             = 3
      max_size             = 20
      disk_size_gb         = 100
      capacity_type        = "ON_DEMAND"
      labels = {
        "workload-type"  = "critical"
        "data-residency" = "eu"
      }
    }
    mixed-event-processing = {
      instance_types           = ["m6i.xlarge", "m6a.xlarge", "m5.xlarge", "m5a.xlarge"]
      on_demand_base_count     = 2
      on_demand_percentage     = 25
      spot_allocation_strategy = "price-capacity-optimized"
      desired_size             = 8
      min_size                 = 2
      max_size                 = 50
      disk_size_gb             = 50
      capacity_type            = "ON_DEMAND"
      labels = {
        "workload-type"  = "event-processing"
        "data-residency" = "eu"
      }
    }
    spot-batch = {
      instance_types           = ["c6i.2xlarge", "c6a.2xlarge", "c5.2xlarge"]
      on_demand_base_count     = 0
      on_demand_percentage     = 0
      spot_allocation_strategy = "price-capacity-optimized"
      desired_size             = 3
      min_size                 = 0
      max_size                 = 30
      disk_size_gb             = 50
      capacity_type            = "SPOT"
      labels = {
        "workload-type"  = "batch"
        "data-residency" = "eu"
      }
      taints = [
        {
          key    = "spot"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      ]
    }
  }

  irsa_roles = var.irsa_roles

  tags = {
    Region        = var.region
    DataResidency = "EU"
  }
}

###############################################################################
# SCP: Deny data operations outside eu-west-1 (applied via AWS Organizations)
# This is defined here as documentation/reference — the actual SCP attachment
# must be performed by the AWS Organizations admin in the management account.
###############################################################################

# The following SCP JSON should be attached to the clevertap-prod-eu AWS account
# via AWS Organizations. It prevents any IAM principal in that account from
# creating, copying, or replicating storage resources outside eu-west-1.
locals {
  eu_data_residency_scp = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyNonEURegions"
        Effect = "Deny"
        Action = [
          "s3:CreateBucket",
          "s3:PutReplicationConfiguration",
          "rds:CreateDBInstance",
          "rds:CreateDBCluster",
          "elasticache:CreateReplicationGroup",
          "dynamodb:CreateTable",
          "kafka:CreateCluster",
          "kinesis:CreateStream",
          "es:CreateDomain",
          "opensearch:CreateDomain",
          "eks:CreateCluster",
          "ec2:RunInstances"
        ]
        Resource = "*"
        Condition = {
          StringNotEquals = {
            "aws:RequestedRegion" = "eu-west-1"
          }
        }
        Principal = { AWS = "*" }
      },
      {
        Sid    = "DenyS3CrossRegionReplication"
        Effect = "Deny"
        Action = [
          "s3:PutReplicationConfiguration"
        ]
        Resource  = "*"
        Principal = { AWS = "*" }
      }
    ]
  })
}

# Output the SCP for manual application via AWS Organizations console or CLI
output "eu_data_residency_scp_json" {
  description = <<-EOF
    SCP JSON to be attached to the EU AWS account via AWS Organizations.
    This enforces that no data storage resources can be created outside eu-west-1.
    Apply with: aws organizations attach-policy --policy-id <id> --target-id <account-id>
  EOF
  value       = local.eu_data_residency_scp
  sensitive   = false
}
