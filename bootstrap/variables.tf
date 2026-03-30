variable "environment" {
  description = "Environment to bootstrap state for (dev, staging, prod, prod-eu)"
  type        = string
}

variable "region" {
  description = "AWS region for the state resources"
  type        = string
}
