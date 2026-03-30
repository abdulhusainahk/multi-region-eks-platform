variable "name" {
  description = "Name prefix for all resources created by this module"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod"
  }
}

variable "region" {
  description = "AWS region where the VPC is deployed"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block"
  }
}

variable "azs" {
  description = "List of Availability Zone names to use (must be >= 2)"
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "At least two Availability Zones must be specified for HA"
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = []
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private/application subnets (one per AZ)"
  type        = list(string)
  default     = []
}

variable "intra_subnet_cidrs" {
  description = "CIDR blocks for intra/database subnets — no internet route (one per AZ)"
  type        = list(string)
  default     = []
}

variable "enable_nat_gateway" {
  description = "Whether to create NAT Gateways for private subnet internet egress"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use a single shared NAT Gateway instead of one per AZ. Cost-saving for non-prod environments"
  type        = bool
  default     = false
}

variable "enable_dns_hostnames" {
  description = "Enable DNS hostnames in the VPC (required for EKS)"
  type        = bool
  default     = true
}

variable "enable_dns_support" {
  description = "Enable DNS resolution in the VPC"
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# VPC Flow Logs
# ---------------------------------------------------------------------------

variable "enable_flow_logs" {
  description = "Enable VPC Flow Logs shipped to S3"
  type        = bool
  default     = true
}

variable "flow_logs_s3_bucket_name" {
  description = "Name of the S3 bucket for VPC Flow Logs. If empty a bucket is created automatically"
  type        = string
  default     = ""
}

variable "flow_logs_retention_days" {
  description = "Days to retain flow logs in S3 before transitioning to cheaper storage"
  type        = number
  default     = 90
}

variable "flow_logs_glacier_days" {
  description = "Days after creation before flow logs are moved to Glacier Instant Retrieval"
  type        = number
  default     = 180
}

variable "flow_logs_expiration_days" {
  description = "Days after creation before flow logs objects are permanently deleted"
  type        = number
  default     = 365
}

# ---------------------------------------------------------------------------
# Transit Gateway
# ---------------------------------------------------------------------------

variable "transit_gateway_id" {
  description = "ID of an existing Transit Gateway to attach to. Leave empty to skip TGW attachment"
  type        = string
  default     = ""
}

variable "transit_gateway_route_table_id" {
  description = "ID of the Transit Gateway Route Table to associate with this VPC attachment"
  type        = string
  default     = ""
}

variable "tgw_propagated_route_tables" {
  description = "List of Transit Gateway Route Table IDs to propagate routes to"
  type        = list(string)
  default     = []
}

variable "tgw_destination_cidrs" {
  description = "List of remote CIDR blocks reachable via the Transit Gateway (added to private/intra route tables)"
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Tags
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Map of additional tags applied to every resource in this module"
  type        = map(string)
  default     = {}
}
