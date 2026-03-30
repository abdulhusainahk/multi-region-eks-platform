variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "eu_aws_account_id" {
  description = "AWS Account ID for the dedicated EU production account"
  type        = string
}

variable "kubernetes_version" {
  type    = string
  default = "1.29"
}

variable "vpc_cidr" {
  description = "CIDR for eu-west-1 VPC. Must not overlap with us-east-1 or ap-south-1"
  type        = string
  default     = "10.50.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.50.0.0/24", "10.50.1.0/24", "10.50.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.50.10.0/22", "10.50.14.0/22", "10.50.18.0/22"]
}

variable "intra_subnet_cidrs" {
  type    = list(string)
  default = ["10.50.100.0/24", "10.50.101.0/24", "10.50.102.0/24"]
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
