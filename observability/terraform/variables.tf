variable "cluster_name" {
  description = "Name of the EKS cluster this observability stack is deployed to"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod"
  }
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider for IRSA"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the EKS OIDC provider for IRSA"
  type        = string
}

variable "alertmanager_secret_arn" {
  description = "ARN of the AWS Secrets Manager secret containing PagerDuty + Slack credentials"
  type        = string
}

variable "grafana_admin_password" {
  description = "Grafana admin password (injected from AWS Secrets Manager in CI)"
  type        = string
  sensitive   = true
}

# Helm chart versions — pin to specific versions for reproducibility
variable "kube_prometheus_stack_version" {
  type    = string
  default = "58.1.3"
}

variable "loki_version" {
  type    = string
  default = "6.2.0"
}

variable "tempo_version" {
  type    = string
  default = "1.7.2"
}

variable "otel_collector_version" {
  type    = string
  default = "0.91.0"
}

variable "tags" {
  type    = map(string)
  default = {}
}
