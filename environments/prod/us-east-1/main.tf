###############################################################################
# Production — us-east-1
# Primary region. HA architecture with one NAT GW per AZ.
# Transit Gateway attachment for cross-region connectivity to ap-south-1.
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
      Environment = "prod"
      ManagedBy   = "terraform"
      Project     = "clevertap"
      Owner       = "platform-engineering"
      CostCenter  = "infrastructure"
    }
  }
}

###############################################################################
# VPC
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
  single_nat_gateway = false # One per AZ in prod for fault isolation

  # Transit Gateway attachment for connectivity to ap-south-1 prod
  transit_gateway_id             = var.transit_gateway_id
  transit_gateway_route_table_id = var.transit_gateway_route_table_id
  tgw_propagated_route_tables    = var.tgw_propagated_route_tables
  tgw_destination_cidrs          = var.tgw_destination_cidrs

  enable_flow_logs          = true
  flow_logs_retention_days  = 90
  flow_logs_glacier_days    = 180
  flow_logs_expiration_days = 365
}

###############################################################################
# EKS Cluster
###############################################################################

module "eks" {
  source = "../../../modules/eks"

  cluster_name       = "clevertap-prod-use1"
  environment        = "prod"
  region             = var.region
  kubernetes_version = var.kubernetes_version

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  # Fully private — no public endpoint in production
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = false

  cloudwatch_log_retention_days = 90

  node_groups = {
    # Critical on-demand pool — guaranteed capacity for core services
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
        "capacity-class" = "on-demand"
      }
    }
    # Mixed pool — event processing / campaign delivery (tolerates Spot)
    mixed-event-processing = {
      instance_types           = ["m6i.xlarge", "m6a.xlarge", "m5.xlarge", "m5d.xlarge", "m5n.xlarge", "m5a.xlarge"]
      on_demand_base_count     = 2
      on_demand_percentage     = 25
      spot_allocation_strategy = "price-capacity-optimized"
      desired_size             = 8
      min_size                 = 2
      max_size                 = 50 # Scale up to 50x baseline for traffic spikes
      disk_size_gb             = 50
      capacity_type            = "ON_DEMAND"
      labels = {
        "workload-type"  = "event-processing"
        "capacity-class" = "mixed"
      }
    }
    # Spot-only pool for analytics/batch workloads
    spot-batch = {
      instance_types           = ["c6i.2xlarge", "c6a.2xlarge", "c5.2xlarge", "c5a.2xlarge", "c5d.2xlarge"]
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
        "capacity-class" = "spot"
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

  # Application-specific IRSA roles
  irsa_roles = var.irsa_roles

  tags = {
    Region = var.region
  }
}
