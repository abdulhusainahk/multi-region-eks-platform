variable "region" {
  type    = string
  default = "us-east-1"
}

variable "kubernetes_version" {
  type    = string
  default = "1.29"
}

variable "vpc_cidr" {
  type    = string
  default = "10.30.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.30.0.0/24", "10.30.1.0/24", "10.30.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.30.10.0/22", "10.30.14.0/22", "10.30.18.0/22"]
}

variable "intra_subnet_cidrs" {
  type    = list(string)
  default = ["10.30.100.0/24", "10.30.101.0/24", "10.30.102.0/24"]
}

# Transit Gateway (shared, managed separately in a network account)
variable "transit_gateway_id" {
  description = "ID of the shared Transit Gateway (managed in network account)"
  type        = string
  default     = ""
}

variable "transit_gateway_route_table_id" {
  description = "TGW route table for us-east-1 spokes"
  type        = string
  default     = ""
}

variable "tgw_propagated_route_tables" {
  description = "TGW route tables to propagate routes to"
  type        = list(string)
  default     = []
}

variable "tgw_destination_cidrs" {
  description = "Remote CIDRs reachable via TGW (e.g., ap-south-1 VPC CIDR)"
  type        = list(string)
  default     = ["10.40.0.0/16"] # ap-south-1 prod VPC CIDR
}

variable "irsa_roles" {
  description = "Application IRSA role configurations"
  type = map(object({
    namespace            = string
    service_account_name = string
    policy_arns          = optional(list(string), [])
    inline_policy        = optional(string, null)
  }))
  default = {}
}
