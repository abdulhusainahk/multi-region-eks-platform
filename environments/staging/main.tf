###############################################################################
# Staging Environment — main.tf
# Single region (us-east-1), HA NAT Gateways (one per AZ), private-only API
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

  default_tags {
    tags = {
      Environment = "staging"
      ManagedBy   = "terraform"
      Project     = "clevertap"
      Owner       = "platform-engineering"
    }
  }
}

###############################################################################
# VPC
###############################################################################

module "vpc" {
  source = "../../modules/vpc"

  name        = "clevertap"
  environment = "staging"
  region      = var.region
  vpc_cidr    = var.vpc_cidr
  azs         = var.azs

  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  intra_subnet_cidrs   = var.intra_subnet_cidrs

  enable_nat_gateway = true
  single_nat_gateway = false # One NAT GW per AZ for better staging parity with prod

  enable_flow_logs          = true
  flow_logs_retention_days  = 60
  flow_logs_glacier_days    = 120
  flow_logs_expiration_days = 180
}

###############################################################################
# EKS Cluster
###############################################################################

module "eks" {
  source = "../../modules/eks"

  cluster_name       = "clevertap-staging"
  environment        = "staging"
  region             = var.region
  kubernetes_version = var.kubernetes_version

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  # Private-only API to match production posture
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = false

  cloudwatch_log_retention_days = 60

  node_groups = {
    # On-Demand base for stable workloads
    on-demand = {
      instance_types       = ["m5.xlarge", "m5a.xlarge", "m6i.xlarge"]
      on_demand_base_count = 2
      on_demand_percentage = 100
      desired_size         = 3
      min_size             = 2
      max_size             = 8
      disk_size_gb         = 50
      capacity_type        = "ON_DEMAND"
      labels = {
        "workload-type" = "stable"
      }
    }
    # Spot pool for batch/burst workloads
    spot = {
      instance_types           = ["m5.xlarge", "m5a.xlarge", "m6i.xlarge", "m5d.xlarge", "m4.xlarge"]
      on_demand_base_count     = 0
      on_demand_percentage     = 0
      spot_allocation_strategy = "price-capacity-optimized"
      desired_size             = 2
      min_size                 = 0
      max_size                 = 10
      disk_size_gb             = 50
      capacity_type            = "SPOT"
      labels = {
        "workload-type" = "burst"
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
}
