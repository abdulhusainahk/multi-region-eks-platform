###############################################################################
# Observability Stack — Terraform Module
#
# Provisions the unified observability infrastructure:
#   - Prometheus + Thanos (metrics, long-term storage on S3)
#   - Grafana Loki (logs, storage on S3)
#   - Grafana Tempo (traces, storage on S3)
#   - Grafana (unified UI, SLO dashboards, alerting)
#   - OTEL Collector (DaemonSet + Gateway)
#   - Alertmanager (routing to PagerDuty + Slack)
#
# Deployed via Helm into the monitoring namespace of each EKS cluster.
# Helm releases are managed by Terraform to keep observability config
# versioned, auditable, and drift-detectable alongside infrastructure.
###############################################################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.26"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.id
  name       = "${var.cluster_name}-observability"

  common_tags = merge(
    {
      Component   = "observability"
      ManagedBy   = "terraform"
      Environment = var.environment
      Cluster     = var.cluster_name
    },
    var.tags
  )
}

###############################################################################
# Kubernetes namespace
###############################################################################

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      name = "monitoring"
    }
  }
}

###############################################################################
# S3 Buckets for long-term storage (Thanos + Loki + Tempo)
###############################################################################

resource "aws_s3_bucket" "thanos" {
  bucket = "${local.name}-thanos-${local.account_id}"
  tags   = merge(local.common_tags, { Name = "${local.name}-thanos" })
}

resource "aws_s3_bucket" "loki" {
  bucket = "${local.name}-loki-${local.account_id}"
  tags   = merge(local.common_tags, { Name = "${local.name}-loki" })
}

resource "aws_s3_bucket" "tempo" {
  bucket = "${local.name}-tempo-${local.account_id}"
  tags   = merge(local.common_tags, { Name = "${local.name}-tempo" })
}

# Common S3 hardening for all observability buckets
resource "aws_s3_bucket_server_side_encryption_configuration" "observability" {
  for_each = {
    thanos = aws_s3_bucket.thanos.id
    loki   = aws_s3_bucket.loki.id
    tempo  = aws_s3_bucket.tempo.id
  }
  bucket = each.value
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "observability" {
  for_each = {
    thanos = aws_s3_bucket.thanos.id
    loki   = aws_s3_bucket.loki.id
    tempo  = aws_s3_bucket.tempo.id
  }
  bucket                  = each.value
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "thanos" {
  bucket = aws_s3_bucket.thanos.id
  rule {
    id     = "thanos-retention"
    status = "Enabled"
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule {
    id     = "loki-retention"
    status = "Enabled"
    transition {
      days          = 14
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 60
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "tempo" {
  bucket = aws_s3_bucket.tempo.id
  rule {
    id     = "tempo-retention"
    status = "Enabled"
    expiration {
      days = 30
    }
  }
}

###############################################################################
# IRSA roles for observability components
###############################################################################

data "aws_iam_policy_document" "observability_assume_role" {
  for_each = {
    thanos = "thanos"
    loki   = "loki"
    tempo  = "tempo"
  }

  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:sub"
      values = [
        "system:serviceaccount:monitoring:${each.key}"
      ]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "observability" {
  for_each = {
    thanos = aws_s3_bucket.thanos.arn
    loki   = aws_s3_bucket.loki.arn
    tempo  = aws_s3_bucket.tempo.arn
  }

  name               = "${var.cluster_name}-${each.key}-irsa"
  assume_role_policy = data.aws_iam_policy_document.observability_assume_role[each.key].json
  tags               = merge(local.common_tags, { Name = "${var.cluster_name}-${each.key}-irsa" })
}

resource "aws_iam_role_policy" "observability_s3" {
  for_each = {
    thanos = aws_s3_bucket.thanos.arn
    loki   = aws_s3_bucket.loki.arn
    tempo  = aws_s3_bucket.tempo.arn
  }

  name = "${each.key}-s3-access"
  role = aws_iam_role.observability[each.key].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          each.value,
          "${each.value}/*"
        ]
      }
    ]
  })
}

###############################################################################
# Kubernetes secret for Alertmanager configuration
# Stores PagerDuty and Slack credentials (populated from AWS Secrets Manager)
###############################################################################

data "aws_secretsmanager_secret_version" "alertmanager" {
  secret_id = var.alertmanager_secret_arn
}

resource "kubernetes_secret_v1" "alertmanager" {
  metadata {
    name      = "alertmanager-config"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  data = {
    "alertmanager.yaml" = templatefile(
      "${path.module}/templates/alertmanager.yaml.tpl",
      jsondecode(data.aws_secretsmanager_secret_version.alertmanager.secret_string)
    )
  }

  type = "Opaque"
}

###############################################################################
# Helm: kube-prometheus-stack (Prometheus + Alertmanager + Grafana + rules)
###############################################################################

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.kube_prometheus_stack_version
  namespace        = kubernetes_namespace_v1.monitoring.metadata[0].name
  create_namespace = false
  timeout          = 600
  atomic           = true
  cleanup_on_fail  = true

  values = [
    templatefile("${path.module}/values/kube-prometheus-stack.yaml.tpl", {
      cluster_name        = var.cluster_name
      environment         = var.environment
      grafana_admin_pass  = var.grafana_admin_password
      thanos_bucket       = aws_s3_bucket.thanos.id
      thanos_region       = local.region
      thanos_role_arn     = aws_iam_role.observability["thanos"].arn
      alertmanager_secret = kubernetes_secret_v1.alertmanager.metadata[0].name
    })
  ]

  depends_on = [
    kubernetes_namespace_v1.monitoring,
    aws_iam_role.observability,
  ]
}

###############################################################################
# Helm: Grafana Loki (distributed mode for production scale)
###############################################################################

resource "helm_release" "loki" {
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  version          = var.loki_version
  namespace        = kubernetes_namespace_v1.monitoring.metadata[0].name
  create_namespace = false
  timeout          = 600
  atomic           = true
  cleanup_on_fail  = true

  values = [
    templatefile("${path.module}/values/loki.yaml.tpl", {
      loki_bucket   = aws_s3_bucket.loki.id
      loki_region   = local.region
      loki_role_arn = aws_iam_role.observability["loki"].arn
    })
  ]

  depends_on = [kubernetes_namespace_v1.monitoring, aws_iam_role.observability]
}

###############################################################################
# Helm: Grafana Tempo
###############################################################################

resource "helm_release" "tempo" {
  name             = "tempo"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "tempo-distributed"
  version          = var.tempo_version
  namespace        = kubernetes_namespace_v1.monitoring.metadata[0].name
  create_namespace = false
  timeout          = 600
  atomic           = true
  cleanup_on_fail  = true

  values = [
    templatefile("${path.module}/values/tempo.yaml.tpl", {
      tempo_bucket   = aws_s3_bucket.tempo.id
      tempo_region   = local.region
      tempo_role_arn = aws_iam_role.observability["tempo"].arn
    })
  ]

  depends_on = [kubernetes_namespace_v1.monitoring, aws_iam_role.observability]
}

###############################################################################
# Helm: OpenTelemetry Collector (DaemonSet + Gateway)
###############################################################################

resource "helm_release" "otel_collector" {
  name             = "otel-collector"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-collector"
  version          = var.otel_collector_version
  namespace        = kubernetes_namespace_v1.monitoring.metadata[0].name
  create_namespace = false
  timeout          = 300
  atomic           = true
  cleanup_on_fail  = true

  values = [
    file("${path.module}/../otel-collector/config.yaml")
  ]

  set = [
    {
      name  = "mode"
      value = "daemonset"
    },
    {
      name  = "clusterRole.create"
      value = "true"
    }
  ]

  depends_on = [
    helm_release.kube_prometheus_stack,
    helm_release.loki,
    helm_release.tempo,
  ]
}

###############################################################################
# ConfigMap: load Prometheus rules from this repository
###############################################################################

resource "kubernetes_config_map_v1" "prometheus_slo_rules" {
  metadata {
    name      = "prometheus-slo-rules"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    labels = {
      "prometheus" = "kube-prometheus-stack"
      "role"       = "prometheus-rulefiles"
    }
  }

  data = {
    "slo-event-ingestion.yaml"       = file("${path.module}/../prometheus/rules/slo-event-ingestion.yaml")
    "recording-event-ingestion.yaml" = file("${path.module}/../prometheus/recording-rules/event-ingestion.yaml")
  }
}

###############################################################################
# ConfigMap: Grafana dashboard provisioning
###############################################################################

resource "kubernetes_config_map_v1" "grafana_dashboards" {
  metadata {
    name      = "grafana-dashboards-clevertap"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    labels = {
      "grafana_dashboard" = "1"
    }
  }

  data = {
    "event-ingestion.json" = file("${path.module}/../grafana/dashboards/event-ingestion.json")
  }
}
