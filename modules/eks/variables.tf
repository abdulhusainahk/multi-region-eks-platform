variable "cluster_name" {
  description = "Name of the EKS cluster"
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
  description = "AWS region where the cluster is deployed"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS control plane"
  type        = string
  default     = "1.29"
}

variable "vpc_id" {
  description = "ID of the VPC where the cluster will be deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for EKS worker nodes (minimum 2, one per AZ)"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least two private subnet IDs are required for HA"
  }
}

variable "control_plane_subnet_ids" {
  description = "Subnet IDs for EKS control plane ENIs. Defaults to private_subnet_ids if not set"
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# API Server Endpoint Access
# ---------------------------------------------------------------------------

variable "cluster_endpoint_private_access" {
  description = "Enable private API server endpoint (required for security hardening)"
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access" {
  description = "Enable public API server endpoint. Should be false in prod"
  type        = bool
  default     = false
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "List of CIDRs that may reach the public endpoint. Only used when public access is enabled"
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Encryption
# ---------------------------------------------------------------------------

variable "cluster_encryption_config_resources" {
  description = "Kubernetes resources to encrypt with the cluster KMS key"
  type        = list(string)
  default     = ["secrets"]
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

variable "cluster_enabled_log_types" {
  description = "EKS control-plane log types to enable"
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cloudwatch_log_retention_days" {
  description = "CloudWatch log group retention in days for EKS control-plane logs"
  type        = number
  default     = 90
}

# ---------------------------------------------------------------------------
# Node Groups
# ---------------------------------------------------------------------------

variable "node_groups" {
  description = <<-EOF
    Map of managed node group configurations. Each entry supports:
      - instance_types         : list of EC2 instance types (for mixed use with launch template)
      - on_demand_base_count   : number of guaranteed On-Demand instances
      - on_demand_percentage   : % of instances above base that should be On-Demand (0-100)
      - spot_allocation_strategy: Spot allocation strategy (price-capacity-optimized recommended)
      - desired_size           : initial desired node count
      - min_size               : minimum node count
      - max_size               : maximum node count
      - disk_size_gb           : root EBS volume size in GiB
      - labels                 : Kubernetes node labels
      - taints                 : list of Kubernetes node taints
      - capacity_type          : ON_DEMAND or SPOT (used when NOT using mixed policy)
  EOF
  type = map(object({
    instance_types           = list(string)
    on_demand_base_count     = optional(number, 1)
    on_demand_percentage     = optional(number, 20)
    spot_allocation_strategy = optional(string, "price-capacity-optimized")
    desired_size             = optional(number, 2)
    min_size                 = optional(number, 1)
    max_size                 = optional(number, 10)
    disk_size_gb             = optional(number, 50)
    labels                   = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
    capacity_type = optional(string, "ON_DEMAND")
  }))
  default = {}
}

# ---------------------------------------------------------------------------
# Cluster Add-ons
# ---------------------------------------------------------------------------

variable "cluster_addons" {
  description = <<-EOF
    Map of EKS managed add-on configurations.
    Key is the add-on name (e.g. "vpc-cni"). Value supports:
      - addon_version           : specific version or "latest"
      - resolve_conflicts       : OVERWRITE | PRESERVE | NONE
      - service_account_role_arn: IRSA role ARN for add-ons that need AWS API access
      - configuration_values   : JSON string of add-on configuration overrides
  EOF
  type = map(object({
    addon_version            = optional(string, null)
    resolve_conflicts        = optional(string, "OVERWRITE")
    service_account_role_arn = optional(string, null)
    configuration_values     = optional(string, null)
  }))
  default = {}
}

# ---------------------------------------------------------------------------
# IRSA (IAM Roles for Service Accounts)
# ---------------------------------------------------------------------------

variable "irsa_roles" {
  description = <<-EOF
    Map of IRSA role definitions to create alongside the cluster.
    Key is a logical name for the role.
      - namespace             : Kubernetes namespace for the service account
      - service_account_name  : Kubernetes service account name
      - policy_arns           : list of managed IAM policy ARNs to attach
      - inline_policy         : optional inline IAM policy JSON string
  EOF
  type = map(object({
    namespace            = string
    service_account_name = string
    policy_arns          = optional(list(string), [])
    inline_policy        = optional(string, null)
  }))
  default = {}
}

# ---------------------------------------------------------------------------
# Access & Auth
# ---------------------------------------------------------------------------

variable "aws_auth_roles" {
  description = "Additional IAM roles to add to the aws-auth ConfigMap"
  type = list(object({
    rolearn  = string
    username = string
    groups   = list(string)
  }))
  default = []
}

variable "aws_auth_users" {
  description = "Additional IAM users to add to the aws-auth ConfigMap"
  type = list(object({
    userarn  = string
    username = string
    groups   = list(string)
  }))
  default = []
}

# ---------------------------------------------------------------------------
# Tags
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Map of additional tags applied to every resource in this module"
  type        = map(string)
  default     = {}
}
