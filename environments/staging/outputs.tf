output "vpc_id" { value = module.vpc.vpc_id }
output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" {
  value     = module.eks.cluster_endpoint
  sensitive = true
}
output "kubeconfig_command" { value = module.eks.kubeconfig_command }
