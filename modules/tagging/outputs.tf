output "tags" {
  description = "Complete map of tags to apply to all resources in this service/environment."
  value       = local.all_tags
}

output "team" {
  description = "Team name (convenience output for use in resource names)."
  value       = var.team
}

output "service" {
  description = "Service name (convenience output for use in resource names)."
  value       = var.service
}

output "environment" {
  description = "Environment name."
  value       = var.environment
}

output "cost_center" {
  description = "Finance cost center code."
  value       = var.cost_center
}

output "name_prefix" {
  description = "Standard resource name prefix: <environment>-<service>"
  value       = "${var.environment}-${var.service}"
}
