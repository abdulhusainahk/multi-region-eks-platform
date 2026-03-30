###############################################################################
# modules/tagging/main.tf
#
# Reusable module that generates the standard tag set for all CleverTap
# AWS resources. Every Terraform module and environment MUST pass tags
# from this module to all resource and sub-module calls.
#
# Usage:
#   module "tags" {
#     source      = "../../modules/tagging"
#     team        = "platform-sre"
#     service     = "event-ingestion"
#     environment = "prod"
#     cost_center = "CC-1001"
#     owner       = "sre@clevertap.com"
#   }
#
#   # Use in resources:
#   resource "aws_instance" "example" {
#     tags = module.tags.tags
#   }
#
#   # Use in modules:
#   module "eks" {
#     source = "../../modules/eks"
#     tags   = module.tags.tags
#   }
###############################################################################

terraform {
  required_version = ">= 1.5.0"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  # Base tags — applied to every resource
  base_tags = {
    team        = var.team
    service     = var.service
    environment = var.environment
    cost-center = var.cost_center
    owner       = var.owner
    managed-by  = "terraform"
    region      = data.aws_region.current.id
  }

  # Merged with any additional tags supplied by the caller
  all_tags = merge(local.base_tags, var.additional_tags)
}
