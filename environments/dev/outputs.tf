output "vpc_id" {
  description = "Dev VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Dev private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

output "cluster_name" {
  description = "Dev EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Dev EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
  sensitive   = true
}

output "kubeconfig_command" {
  description = "Command to configure kubectl for dev cluster"
  value       = module.eks.kubeconfig_command
}
