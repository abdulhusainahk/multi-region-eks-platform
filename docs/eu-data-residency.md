# Section 1c: EU Data Residency Architecture

## Problem Statement

The platform is expanding into the EU. Data residency laws (GDPR Article 44–49) require that **EU customer data never leave eu-west-1**. We must still maintain a **single control plane** for deployments across all regions.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│  GitHub Actions (Control Plane — deploys to all regions)                │
│  - Single pipeline, per-region credentials via OIDC                     │
│  - EU deployments use isolated AWS account + IAM role                   │
└──────────────────────┬───────────────────┬──────────────────────────────┘
                       │                   │
          Non-EU regions                EU Region
                       │                   │
         ┌─────────────┴────┐   ┌──────────┴───────────────┐
         │  clevertap-prod  │   │  clevertap-prod-eu        │
         │  AWS Account     │   │  AWS Account              │
         │                  │   │  (GDPR-isolated)          │
         │  us-east-1 EKS   │   │  eu-west-1 EKS            │
         │  ap-south-1 EKS  │   │                           │
         │                  │   │  SCP: DenyNonEURegions    │
         │  Transit Gateway │   │  NO TGW to non-EU         │
         └──────────────────┘   └───────────────────────────┘
```

---

## Cluster Federation vs. Isolation Decision

### Why Isolation (Not Federation)

We choose **cluster isolation** over federation (e.g., KubeFed, ArgoCD ApplicationSets with hub-spoke) for the EU:

| Approach | Pros | Cons |
|----------|------|------|
| **Federation** (hub in us-east-1) | Single control plane, shared tooling | Hub cluster can access EU cluster; data might transit non-EU networks; hard to enforce at network layer |
| **Isolation** (separate EU account + cluster) | Hard network boundary, AWS account = blast radius | Slightly more operational overhead |

**For GDPR, isolation wins.** The EU cluster is:
- In a **dedicated AWS account** (`clevertap-prod-eu`)
- Connected to **no Transit Gateway** that bridges non-EU regions
- Protected by **AWS Organizations SCPs** that deny resource creation outside eu-west-1
- Managed with **separate credentials** in CI/CD

### Why Not VPC Peering or TGW to EU

VPC peering and Transit Gateway create network paths between regions. Even if application code doesn't intentionally send EU data to us-east-1, a misconfigured service could. The correct control is to **have no network path**, enforced at both the network layer (no TGW attachment) and the IAM layer (SCP).

---

## IAM Boundary Enforcement

### Layer 1: AWS Organizations SCP

An SCP is attached to the `clevertap-prod-eu` account that denies:
- Creating storage (S3, RDS, DynamoDB, Kafka, Kinesis, ElasticSearch) outside eu-west-1
- Creating compute (EKS, EC2) outside eu-west-1
- S3 cross-region replication

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyNonEURegions",
      "Effect": "Deny",
      "Action": [
        "s3:CreateBucket",
        "s3:PutReplicationConfiguration",
        "rds:CreateDBInstance",
        "rds:CreateDBCluster",
        "dynamodb:CreateTable",
        "kafka:CreateCluster",
        "kinesis:CreateStream",
        "eks:CreateCluster",
        "ec2:RunInstances"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:RequestedRegion": "eu-west-1"
        }
      }
    }
  ]
}
```

**This SCP applies to every IAM principal in the account — including the GitHub Actions role.** Even if CI/CD is misconfigured, it cannot create resources outside eu-west-1.

### Layer 2: IAM Permission Boundaries

Every IAM role in the `clevertap-prod-eu` account has a **permission boundary** that includes:

```hcl
Condition = {
  StringEquals = {
    "aws:RequestedRegion" = "eu-west-1"
  }
}
```

Permission boundaries are attached at role creation time via the account's IAM baseline Terraform.

### Layer 3: KMS Key Policy

KMS keys used for data encryption in eu-west-1 have a key policy that **denies use from any region other than eu-west-1**:

```json
{
  "Sid": "DenyKeyUseOutsideEU",
  "Effect": "Deny",
  "Principal": {"AWS": "*"},
  "Action": "kms:*",
  "Resource": "*",
  "Condition": {
    "StringNotEquals": {
      "aws:RequestedRegion": "eu-west-1"
    }
  }
}
```

This means even if someone somehow gets hold of the key ARN, they cannot use it to decrypt data from a non-EU region.

### Layer 4: IRSA Scoping

IRSA roles in the EU cluster are scoped to only the EU account and eu-west-1:

```hcl
condition {
  test     = "StringEquals"
  variable = "aws:RequestedRegion"
  values   = ["eu-west-1"]
}
```

Application pods cannot make AWS API calls that would route data outside eu-west-1.

---

## Single Control Plane for Deployments

### How It Works

We maintain a **single CI/CD pipeline** (GitHub Actions) that can deploy to all regions. The pipeline uses **OIDC-based authentication** with separate IAM roles per target account:

```yaml
# Non-EU regions
role-to-assume: ${{ secrets.AWS_ROLE_ARN_PROD }}
aws-region: us-east-1

# EU region — completely separate IAM role in the isolated EU account
role-to-assume: ${{ secrets.AWS_ROLE_ARN_PROD_EU }}
aws-region: eu-west-1
```

The GitHub Actions runner itself never holds EU customer data — it only holds deployment artifacts (container image tags, Terraform plans). These do not contain PII.

### Pipeline Enforcement of Data Residency

The CI/CD pipeline enforces residency through three mechanisms:

#### 1. Separate `allowed_account_ids` in Terraform provider

```hcl
provider "aws" {
  region              = "eu-west-1"
  allowed_account_ids = [var.eu_aws_account_id]
}
```

This causes Terraform to fail immediately if it's accidentally run against the wrong account.

#### 2. Environment-specific IAM roles with condition keys

The `AWS_ROLE_ARN_PROD_EU` GitHub Actions secret is an IAM role that:
- Only exists in the `clevertap-prod-eu` account
- Has a trust policy that only allows assumption from the `prod/eu-west-1` workflow path
- Cannot be assumed from non-EU deployment steps

```json
{
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:sub": 
        "repo:clevertap/infra:environment:prod-eu"
    }
  }
}
```

#### 3. Checkov policy: eu-west-1 boundary check

A custom Checkov policy (`.checkov/eu_data_residency_check.py`) runs in the validate stage and fails if any `environments/prod/eu-west-1/` Terraform resource specifies a region other than eu-west-1.

---

## Data Flow Architecture

```
EU Customer Request
        │
        ▼
Route 53 (latency-based routing → eu-west-1)
        │
        ▼
ALB (in eu-west-1 public subnets)
        │
        ▼
EKS eu-west-1 (clevertap-prod-euw1)
  ├── Event collection pods
  ├── Campaign processing pods
  └── Analytics pods
        │
        ▼
Data stores (all in eu-west-1):
  ├── RDS Aurora (intra subnets, eu-west-1)
  ├── ElastiCache Redis (intra subnets, eu-west-1)
  ├── MSK Kafka (intra subnets, eu-west-1)
  └── S3 buckets (eu-west-1, no replication)

NO DATA PATH TO us-east-1 or ap-south-1
```

### What CAN Cross Regions

Some **non-PII operational data** is allowed to cross regions:
- Container image layers (pulled from ECR us-east-1 — images contain no customer data)
- Terraform state file metadata (non-PII)
- CloudWatch metrics aggregation to a global dashboard (metrics are anonymized)

For ECR specifically, we replicate image tags (not customer data) to an ECR repo in eu-west-1 so pulls stay within the region even at the data plane level.

---

## Runbook: EU Data Residency Incident Response

If an alert fires suggesting EU data may have left eu-west-1:

1. **Isolate**: Remove the suspect network path immediately (security group rule, route table entry)
2. **Assess**: Query CloudTrail with `aws:RequestedRegion != eu-west-1` filter to identify all cross-region API calls from the EU account in the past 24 hours
3. **Notify**: GDPR Article 33 requires notifying the supervisory authority within 72 hours of discovering a personal data breach
4. **Root cause**: Review Terraform plan for EU environment to verify no TGW was accidentally added
5. **Verify SCPs**: Confirm the `DenyNonEURegions` SCP is still attached to the account
6. **Post-mortem**: Document in the runbook and update automated tests

---

## Compliance Audit Trail

Every Terraform apply in the EU environment produces:
- **GitHub Actions audit log**: who triggered the apply, when, what SHA
- **CloudTrail**: all AWS API calls with IAM principal, timestamp, region
- **S3 state versioning**: every state transition is retained indefinitely
- **VPC Flow Logs**: all network traffic in/out of EU subnets, retained 365 days

These logs are **stored in eu-west-1 only** and cannot be replicated outside the EU by policy.
