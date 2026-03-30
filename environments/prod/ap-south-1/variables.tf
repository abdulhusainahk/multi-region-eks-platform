variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "kubernetes_version" {
  type    = string
  default = "1.29"
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.40.0.0/24", "10.40.1.0/24", "10.40.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.40.10.0/22", "10.40.14.0/22", "10.40.18.0/22"]
}

variable "intra_subnet_cidrs" {
  type    = list(string)
  default = ["10.40.100.0/24", "10.40.101.0/24", "10.40.102.0/24"]
}

variable "transit_gateway_id" {
  type    = string
  default = ""
}

variable "transit_gateway_route_table_id" {
  type    = string
  default = ""
}

variable "tgw_propagated_route_tables" {
  type    = list(string)
  default = []
}

variable "tgw_destination_cidrs" {
  description = "Remote CIDRs reachable via TGW (e.g., us-east-1 prod VPC CIDR)"
  type        = list(string)
  default     = ["10.30.0.0/16"] # us-east-1 prod VPC CIDR
}

variable "irsa_roles" {
  type = map(object({
    namespace            = string
    service_account_name = string
    policy_arns          = optional(list(string), [])
    inline_policy        = optional(string, null)
  }))
  default = {}
}
