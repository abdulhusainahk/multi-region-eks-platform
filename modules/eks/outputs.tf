###############################################################################
# EKS Module — outputs.tf
###############################################################################

output "cluster_id" {
  description = "EKS cluster ID (same as cluster name)"
  value       = aws_eks_cluster.this.id
}

output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster"
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "Endpoint for the EKS cluster API server"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  description = "Kubernetes server version of the EKS cluster"
  value       = aws_eks_cluster.this.version
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster control plane"
  value       = aws_security_group.cluster.id
}

output "node_security_group_id" {
  description = "Security group ID attached to the EKS worker nodes"
  value       = aws_security_group.node.id
}

output "cluster_oidc_issuer_url" {
  description = "URL for the OpenID Connect identity provider (used for IRSA)"
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider associated with the cluster"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "cluster_role_arn" {
  description = "IAM role ARN used by the EKS control plane"
  value       = aws_iam_role.cluster.arn
}

output "node_role_arn" {
  description = "IAM role ARN used by worker nodes"
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "IAM role name used by worker nodes"
  value       = aws_iam_role.node.name
}

output "node_group_ids" {
  description = "Map of node group names to their IDs"
  value       = { for k, v in aws_eks_node_group.this : k => v.id }
}

output "node_group_statuses" {
  description = "Map of node group names to their current status"
  value       = { for k, v in aws_eks_node_group.this : k => v.status }
}

output "irsa_role_arns" {
  description = "Map of IRSA logical names to IAM role ARNs"
  value       = { for k, v in aws_iam_role.irsa : k => v.arn }
}

output "cluster_kms_key_arn" {
  description = "ARN of the KMS key used to encrypt Kubernetes Secrets"
  value       = aws_kms_key.eks.arn
}

output "cluster_log_group_name" {
  description = "Name of the CloudWatch Log Group for EKS control-plane logs"
  value       = aws_cloudwatch_log_group.eks.name
}

output "kubeconfig_command" {
  description = "AWS CLI command to update local kubeconfig for this cluster"
  value       = "aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.region}"
}
