variable "region" {
  description = "AWS region for the dev environment"
  type        = string
  default     = "us-east-1"
}

variable "kubernetes_version" {
  description = "Kubernetes version for EKS"
  type        = string
  default     = "1.29"
}

variable "vpc_cidr" {
  description = "CIDR block for dev VPC"
  type        = string
  default     = "10.10.0.0/16"
}

variable "azs" {
  description = "Availability zones for dev environment"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "public_subnet_cidrs" {
  description = "CIDRs for public subnets"
  type        = list(string)
  default     = ["10.10.0.0/24", "10.10.1.0/24", "10.10.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDRs for private subnets"
  type        = list(string)
  default     = ["10.10.10.0/23", "10.10.12.0/23", "10.10.14.0/23"]
}

variable "intra_subnet_cidrs" {
  description = "CIDRs for intra (database) subnets"
  type        = list(string)
  default     = ["10.10.100.0/24", "10.10.101.0/24", "10.10.102.0/24"]
}

variable "developer_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint (office/VPN IPs)"
  type        = list(string)
  default     = []
}
