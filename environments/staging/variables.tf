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
  default = "10.20.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.0.0/24", "10.20.1.0/24", "10.20.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.10.0/23", "10.20.12.0/23", "10.20.14.0/23"]
}

variable "intra_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.100.0/24", "10.20.101.0/24", "10.20.102.0/24"]
}
