# Section 1b: Terraform State Management & Drift Detection

## State Structure Across Multiple Accounts, Regions, and Teams

### Design Principles

Terraform state is the source of truth for infrastructure. Good state architecture must satisfy:

1. **Isolation** — a bug in one environment cannot corrupt another
2. **Access control** — least-privilege; developers can plan but not apply prod
3. **Auditability** — every state change is versioned and attributable
4. **Performance** — large monolithic state files slow down `plan`/`apply`
5. **Collaboration** — concurrent changes must be serialized without conflicts

---

### Account Structure

We use a **multi-account AWS Organizations** structure:

```
Management Account (billing, SCPs, AWS Organizations)
├── clevertap-dev          (AWS Account)
├── clevertap-staging      (AWS Account)
├── clevertap-prod         (AWS Account — us-east-1, ap-south-1)
├── clevertap-prod-eu      (AWS Account — eu-west-1, GDPR-isolated)
└── clevertap-network      (AWS Account — Transit Gateway, shared VPCs)
```

Each account has its own:
- S3 bucket for state (KMS-encrypted, versioned, public-access blocked)
- DynamoDB table for state locking
- IAM roles (per-team, per-environment, scoped to read vs. write)

### State File Layout

```
S3 bucket: clevertap-terraform-state-{env}
├── bootstrap/
│   └── terraform.tfstate          # The bootstrap itself (special handling)
├── network/
│   └── terraform.tfstate          # Transit Gateway, shared VPCs
├── dev/
│   └── us-east-1/
│       └── terraform.tfstate
├── staging/
│   └── us-east-1/
│       └── terraform.tfstate
├── prod/
│   ├── us-east-1/
│   │   └── terraform.tfstate
│   └── ap-south-1/
│       └── terraform.tfstate
└── prod-eu/
    └── eu-west-1/
        └── terraform.tfstate      # EU state in separate bucket (eu-west-1)
```

**Key decisions:**
- **One state file per environment × region** pair. This keeps blast radius small and `plan` fast.
- **Separate AWS accounts** (not just separate S3 keys) for dev/staging/prod. SCPs on each account are the hard guardrail.
- **EU state lives in a separate bucket in eu-west-1** so that even Terraform metadata never leaves the EU.

### State Sharing Across Teams

Teams that need to reference each other's outputs (e.g., the app team needs VPC IDs) use **remote state data sources**, not direct module calls:

```hcl
# In application team's Terraform
data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket = "clevertap-terraform-state-prod"
    key    = "prod/us-east-1/terraform.tfstate"
    region = "us-east-1"
  }
}

# Consume outputs safely
locals {
  vpc_id             = data.terraform_remote_state.vpc.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.vpc.outputs.private_subnet_ids
}
```

This allows teams to own their own state while still accessing shared infrastructure data.

### IAM Roles per Team

```
Role: terraform-platform-read   → s3:GetObject, s3:ListBucket, dynamodb:GetItem
Role: terraform-platform-write  → All of the above + s3:PutObject, dynamodb:PutItem, dynamodb:DeleteItem
Role: terraform-app-read        → Read-only access to platform state bucket
```

Team members assume these roles via OIDC (GitHub Actions) or SSO (interactive). No one stores long-lived credentials.

---

## Drift Detection and Remediation

### What is Infrastructure Drift?

Drift occurs when the actual state of resources in AWS diverges from what Terraform tracks in state. Common causes:

- Manual changes via AWS Console or CLI (click-ops)
- AWS service auto-modifications (e.g., security group rule added by AWS Shield)
- Resources modified by another tool (CloudFormation, CDK) in the same account
- Incomplete or failed Terraform applies that leave partial state

### Tooling

#### 1. Terraform Plan (`-detailed-exitcode`)

The primary drift detection mechanism. Exit code 2 means "changes detected."

```bash
terraform plan -detailed-exitcode -input=false
# Exit 0: no changes
# Exit 1: error
# Exit 2: changes detected (DRIFT)
```

The `drift-detection.yml` GitHub Actions workflow runs this daily for every environment and opens/updates GitHub Issues when drift is found.

#### 2. Driftctl (optional, deeper drift analysis)

[Driftctl](https://driftctl.com/) goes beyond Terraform state and scans all resources in an account — including resources that Terraform has never managed. Useful for finding "shadow infrastructure" created outside IaC.

```bash
driftctl scan --from tfstate+s3://clevertap-terraform-state-prod/prod/us-east-1/terraform.tfstate
```

Run as a weekly scheduled job, output routed to a Slack channel.

#### 3. AWS Config Rules

AWS Config continuously monitors resource configurations and can alert when resources deviate from desired state. Useful for:
- Security group rule changes
- S3 bucket policy modifications
- IAM policy attachments
- EC2 instance type changes

Config Rules complement Terraform plan by catching drift at the AWS API level in real time (not just on a schedule).

#### 4. Checkov (CI security drift)

Security-focused static analysis that runs on every PR. Catches misconfigurations before they reach state — acts as a "pre-drift" control.

### Drift Alerting

Alerts flow through three channels:

| Severity | Channel | Examples |
|----------|---------|---------|
| P1 (security drift) | PagerDuty + Slack #incidents | Security group opened to 0.0.0.0/0, S3 bucket made public |
| P2 (config drift) | Slack #infra-alerts + GitHub Issue | Node group size changed, addon version changed |
| P3 (informational) | GitHub Issue only | Tag change, resource name change |

### Drift Remediation Workflow

```
Drift Detected
     │
     ▼
Is the drift intentional?
     │
   ┌─┴───────────────────────┐
   │ YES                     │ NO
   ▼                         ▼
Update Terraform code    Re-apply Terraform
to match reality         to restore desired state
   │                         │
   ▼                         ▼
terraform import         terraform apply
(if new resource)        (rolls back manual change)
   │                         │
   └────────────────┬────────┘
                    ▼
           Post-mortem / runbook
           update to prevent recurrence
```

**Golden rule:** All drift, intentional or not, must be resolved within:
- 4 hours for prod security groups, IAM, S3 policies
- 24 hours for prod compute/network configuration  
- 72 hours for dev/staging

### Preventing Drift

1. **Break-glass IAM roles** — direct AWS console access requires a time-limited IAM role with session recording. Every use triggers a CloudTrail alert.
2. **AWS Config remediation** — auto-reverts unapproved security group changes within 5 minutes.
3. **Terraform sentinel policies** (if using Terraform Cloud/Enterprise) — block applies that violate policy.
4. **Regular `terraform refresh`** runs — keep state in sync with reality without applying changes.
