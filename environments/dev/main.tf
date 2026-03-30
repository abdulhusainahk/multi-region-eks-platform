###############################################################################
# Dev Environment — main.tf
# Single region (us-east-1), single NAT Gateway for cost saving
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
      Environment = "dev"
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
  environment = "dev"
  region      = var.region
  vpc_cidr    = var.vpc_cidr
  azs         = var.azs

  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  intra_subnet_cidrs   = var.intra_subnet_cidrs

  enable_nat_gateway = true
  single_nat_gateway = true # Single NAT GW to reduce cost in dev

  enable_flow_logs          = true
  flow_logs_retention_days  = 30 # Shorter retention for dev
  flow_logs_glacier_days    = 60
  flow_logs_expiration_days = 90
}

###############################################################################
# EKS Cluster
###############################################################################

module "eks" {
  source = "../../modules/eks"

  cluster_name       = "clevertap-dev"
  environment        = "dev"
  region             = var.region
  kubernetes_version = var.kubernetes_version

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  # In dev, allow public endpoint for developer convenience with IP restriction
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.developer_cidrs

  cloudwatch_log_retention_days = 30

  node_groups = {
    general = {
      instance_types           = ["t3.medium", "t3.large", "t3a.medium", "t3a.large"]
      on_demand_base_count     = 1
      on_demand_percentage     = 0 # Maximize Spot in dev for cost savings
      spot_allocation_strategy = "price-capacity-optimized"
      desired_size             = 2
      min_size                 = 1
      max_size                 = 5
      disk_size_gb             = 30
      capacity_type            = "SPOT"
      labels = {
        "workload-type" = "general"
        "env"           = "dev"
      }
    }
  }
}
