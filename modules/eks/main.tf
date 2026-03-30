###############################################################################
# EKS Module — main.tf
#
# Provisions a production-grade EKS cluster with:
#   - Private-only API server endpoint
#   - KMS encryption for Kubernetes Secrets
#   - IRSA (IAM Roles for Service Accounts) via OIDC provider
#   - Managed node groups with On-Demand + Spot mixed instance policy
#   - Managed cluster add-ons (VPC CNI, CoreDNS, kube-proxy, EBS CSI driver)
#   - CloudWatch container insights log group
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
  }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  control_plane_subnet_ids = (
    length(var.control_plane_subnet_ids) > 0
    ? var.control_plane_subnet_ids
    : var.private_subnet_ids
  )

  common_tags = merge(
    {
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
      Environment                                 = var.environment
      Region                                      = var.region
      ManagedBy                                   = "terraform"
    },
    var.tags
  )
}

###############################################################################
# KMS Key — Kubernetes Secrets encryption at rest
###############################################################################

resource "aws_kms_key" "eks" {
  description             = "EKS Secrets encryption key for cluster ${var.cluster_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-eks-secrets-key" })
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-eks-secrets"
  target_key_id = aws_kms_key.eks.key_id
}

resource "aws_kms_key_policy" "eks" {
  key_id = aws_kms_key.eks.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${local.partition}:iam::${local.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow EKS service use"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })
}

###############################################################################
# CloudWatch Log Group for EKS control-plane logs
###############################################################################

resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.cloudwatch_log_retention_days
  kms_key_id        = aws_kms_key.eks.arn

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-eks-log-group" })
}

###############################################################################
# IAM Role — EKS Cluster (control plane)
###############################################################################

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-cluster-role" })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "cluster_vpc_resource_controller" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSVPCResourceController"
}

###############################################################################
# Security Group — Cluster control plane
###############################################################################

resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "EKS cluster control-plane security group"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-cluster-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "cluster_ingress_node_https" {
  description              = "Allow node groups to communicate with cluster API"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.cluster.id
  source_security_group_id = aws_security_group.node.id
}

resource "aws_security_group_rule" "cluster_egress_all" {
  description       = "Allow cluster control-plane egress"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.cluster.id
  cidr_blocks       = ["0.0.0.0/0"]
}

###############################################################################
# Security Group — Worker Nodes
###############################################################################

resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-node-sg"
  description = "EKS worker node security group"
  vpc_id      = var.vpc_id

  tags = merge(
    local.common_tags,
    {
      Name                                        = "${var.cluster_name}-node-sg"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "node_ingress_self" {
  description              = "Allow nodes to communicate with each other"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  security_group_id        = aws_security_group.node.id
  source_security_group_id = aws_security_group.node.id
}

resource "aws_security_group_rule" "node_ingress_cluster" {
  description              = "Allow worker nodes to receive traffic from the cluster API"
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.node.id
  source_security_group_id = aws_security_group.cluster.id
}

resource "aws_security_group_rule" "node_egress_all" {
  description       = "Allow worker nodes full egress"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.node.id
  cidr_blocks       = ["0.0.0.0/0"]
}

###############################################################################
# EKS Cluster
###############################################################################

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = local.control_plane_subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = var.cluster_endpoint_private_access
    endpoint_public_access  = var.cluster_endpoint_public_access
    public_access_cidrs     = var.cluster_endpoint_public_access ? var.cluster_endpoint_public_access_cidrs : null
  }

  encryption_config {
    resources = var.cluster_encryption_config_resources
    provider {
      key_arn = aws_kms_key.eks.arn
    }
  }

  enabled_cluster_log_types = var.cluster_enabled_log_types

  # Ensure log group exists before cluster tries to write to it
  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_iam_role_policy_attachment.cluster_vpc_resource_controller,
    aws_cloudwatch_log_group.eks,
    aws_kms_key_policy.eks,
  ]

  tags = merge(local.common_tags, { Name = var.cluster_name })

  lifecycle {
    ignore_changes = [
      # Version upgrades should be performed through a dedicated process
      # (blue/green or rolling) rather than Terraform in-place updates
      version,
    ]
  }
}

###############################################################################
# IAM Role — Worker Nodes
###############################################################################

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-node-role" })
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_read" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# SSM managed instance core: enables Session Manager for node access without
# requiring a bastion host or open SSH port
resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

###############################################################################
# Launch Template — shared defaults for all node groups
###############################################################################

resource "aws_launch_template" "node" {
  name_prefix = "${var.cluster_name}-node-"
  description = "Shared launch template for EKS managed node groups"

  # Security hardening: no public IPs on nodes
  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.node.id]
    delete_on_termination       = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      # Size is overridden per node group via var.node_groups[].disk_size_gb
      volume_size           = 50
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.eks.arn
      delete_on_termination = true
      throughput            = 125
      iops                  = 3000
    }
  }

  metadata_options {
    # IMDSv2 enforced — prevents SSRF-based credential theft
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${var.cluster_name}-node" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.common_tags, { Name = "${var.cluster_name}-node-vol" })
  }

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-node-lt" })

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Managed Node Groups (On-Demand + Spot mixed)
###############################################################################

resource "aws_eks_node_group" "this" {
  for_each = var.node_groups

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  # Use launch template for consistent security configuration
  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  scaling_config {
    desired_size = each.value.desired_size
    min_size     = each.value.min_size
    max_size     = each.value.max_size
  }

  update_config {
    # Allow up to 33% of nodes unavailable during rolling updates
    max_unavailable_percentage = 33
  }

  # Mixed On-Demand + Spot policy
  # When multiple instance types are listed, EKS evaluates all types for
  # Spot availability which dramatically improves Spot capacity stability.
  # instance_types is set here (not in the launch template) so EKS can
  # schedule across all types in the list for capacity optimisation.
  instance_types = each.value.instance_types
  capacity_type  = each.value.capacity_type

  # Node labels & taints
  labels = merge(
    {
      "node-group"    = each.key
      "capacity-type" = each.value.capacity_type
    },
    each.value.labels
  )

  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_read,
  ]

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_name}-${each.key}"
      # Karpenter-compatible discovery tags (optional, for future Karpenter adoption)
      "karpenter.sh/discovery" = var.cluster_name
    }
  )

  lifecycle {
    # Ignore desired_size changes to allow cluster autoscaler to manage scale
    ignore_changes = [scaling_config[0].desired_size]
  }
}
