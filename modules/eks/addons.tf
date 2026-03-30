###############################################################################
# EKS Module — addons.tf
#
# Manages EKS cluster add-ons via Terraform so their lifecycle is auditable,
# version-pinned, and drift-detected.  The four core add-ons are pre-wired;
# callers can extend via var.cluster_addons.
#
# Add-on versions should be explicitly pinned per cluster Kubernetes version.
# See: https://docs.aws.amazon.com/eks/latest/userguide/managing-add-ons.html
###############################################################################

locals {
  # Base add-ons that every cluster receives.  Callers can override these
  # by providing matching keys in var.cluster_addons.
  default_addons = {
    vpc-cni = {
      # VPC CNI manages pod networking and must be updated carefully.
      # IRSA role is provided so CNI can call EC2 APIs for IP management.
      resolve_conflicts        = "OVERWRITE"
      service_account_role_arn = aws_iam_role.vpc_cni_irsa.arn
      configuration_values = jsonencode({
        env = {
          # Enable prefix delegation to increase pod density per node
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    coredns = {
      resolve_conflicts    = "OVERWRITE"
      configuration_values = null
    }
    kube-proxy = {
      resolve_conflicts    = "OVERWRITE"
      configuration_values = null
    }
    aws-ebs-csi-driver = {
      resolve_conflicts        = "OVERWRITE"
      service_account_role_arn = aws_iam_role.ebs_csi_irsa.arn
      configuration_values     = null
    }
  }

  # Merge defaults with caller-provided overrides (caller wins)
  merged_addons = merge(local.default_addons, var.cluster_addons)
}

resource "aws_eks_addon" "this" {
  for_each = local.merged_addons

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = lookup(each.value, "addon_version", null)
  resolve_conflicts_on_create = lookup(each.value, "resolve_conflicts", "OVERWRITE")
  resolve_conflicts_on_update = lookup(each.value, "resolve_conflicts", "OVERWRITE")
  service_account_role_arn    = lookup(each.value, "service_account_role_arn", null)
  configuration_values        = lookup(each.value, "configuration_values", null)

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-addon-${each.key}" })

  depends_on = [
    aws_eks_node_group.this,
    aws_iam_role.vpc_cni_irsa,
    aws_iam_role.ebs_csi_irsa,
  ]
}

###############################################################################
# IRSA for VPC CNI add-on
# The CNI plugin must be able to call EC2 APIs to assign/unassign IPs.
###############################################################################

data "aws_iam_policy_document" "vpc_cni_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-node"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vpc_cni_irsa" {
  name               = "${var.cluster_name}-vpc-cni-irsa"
  assume_role_policy = data.aws_iam_policy_document.vpc_cni_assume_role.json

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-vpc-cni-irsa" })
}

resource "aws_iam_role_policy_attachment" "vpc_cni_irsa" {
  role       = aws_iam_role.vpc_cni_irsa.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

###############################################################################
# IRSA for EBS CSI Driver
# Allows the CSI driver to provision and attach EBS volumes.
###############################################################################

data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi_irsa" {
  name               = "${var.cluster_name}-ebs-csi-irsa"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-ebs-csi-irsa" })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_irsa" {
  role       = aws_iam_role.ebs_csi_irsa.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
