###############################################################################
# EKS Module — irsa.tf
#
# Sets up IAM Roles for Service Accounts (IRSA) using the cluster's OIDC
# provider. This is the AWS-recommended approach for granting fine-grained
# AWS permissions to Kubernetes workloads without using node-level instance
# profiles (which would over-provision permissions to all pods on a node).
###############################################################################

###############################################################################
# OIDC Provider — enables IRSA for the cluster
###############################################################################

# Fetch the OIDC issuer TLS certificate thumbprint automatically
data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-oidc-provider" })
}

###############################################################################
# Helper: build the OIDC assume-role trust policy for a service account
###############################################################################

# Produces the minimal trust policy required for IRSA
data "aws_iam_policy_document" "irsa_assume_role" {
  for_each = var.irsa_roles

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
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.service_account_name}"]
    }
    condition {
      # Restrict token audience to prevent confused-deputy attacks
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

###############################################################################
# IRSA Roles
###############################################################################

resource "aws_iam_role" "irsa" {
  for_each = var.irsa_roles

  name               = "${var.cluster_name}-irsa-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume_role[each.key].json

  tags = merge(
    local.common_tags,
    {
      Name           = "${var.cluster_name}-irsa-${each.key}"
      ServiceAccount = each.value.service_account_name
      Namespace      = each.value.namespace
    }
  )
}

resource "aws_iam_role_policy_attachment" "irsa" {
  # Flatten the map-of-lists into individual managed_policy attachments
  for_each = {
    for attachment in flatten([
      for role_key, role in var.irsa_roles : [
        for policy_arn in role.policy_arns : {
          key        = "${role_key}__${replace(policy_arn, "/", "_")}"
          role_key   = role_key
          policy_arn = policy_arn
        }
      ]
    ]) : attachment.key => attachment
  }

  role       = aws_iam_role.irsa[each.value.role_key].name
  policy_arn = each.value.policy_arn
}

resource "aws_iam_role_policy" "irsa_inline" {
  for_each = {
    for k, v in var.irsa_roles : k => v if v.inline_policy != null
  }

  name   = "${var.cluster_name}-irsa-${each.key}-inline"
  role   = aws_iam_role.irsa[each.key].name
  policy = each.value.inline_policy
}
