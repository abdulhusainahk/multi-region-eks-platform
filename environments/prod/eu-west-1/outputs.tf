output "vpc_id" { value = module.vpc.vpc_id }
output "private_subnet_ids" { value = module.vpc.private_subnet_ids }
output "cluster_name" { value = module.eks.cluster_name }
output "cluster_arn" { value = module.eks.cluster_arn }
output "oidc_provider_arn" { value = module.eks.oidc_provider_arn }
output "cluster_endpoint" {
  value     = module.eks.cluster_endpoint
  sensitive = true
}
output "kubeconfig_command" { value = module.eks.kubeconfig_command }
