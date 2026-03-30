# Section 3b: Internal Developer Platform (IDP)

## The Problem

Product teams are blocked waiting for DevOps to provision feature test environments.
This creates two failure modes:
1. **Bottleneck**: DevOps is a shared resource; engineers wait days for environments
2. **Workarounds**: Engineers hard-code credentials, reuse shared environments, or skip
   testing altogether — all of which introduce risk

The goal is to enable **self-serve environment provisioning** without sacrificing
security, cost control, or operational hygiene.

---

## Design: Self-Serve Ephemeral Environments

### Architecture Overview

```
Engineer (GitHub PR)
    │
    │  Comment: /env create feature-payment-v2
    ▼
GitHub Actions (IDP Bot Workflow)
    │
    ├─ 1. Validate request (quota check, security scan)
    ├─ 2. Terraform workspace create (isolated state)
    ├─ 3. Provision resources (RDS, ElastiCache, SQS)
    ├─ 4. Deploy service stack (Helm into isolated namespace)
    ├─ 5. Post environment URL as PR comment
    └─ 6. Register TTL in DynamoDB (auto-cleanup scheduler)

                           ┌──────────────────────────┐
                           │  AWS Account: sandbox     │
                           │                           │
                           │  VPC (shared)             │
                           │  ┌──────────────────┐     │
                           │  │ ns: feat-payment  │     │
                           │  │  - Deployment     │     │
                           │  │  - RDS (t4g.small)│     │
                           │  │  - ElastiCache    │     │
                           │  │  - SQS queues     │     │
                           │  └──────────────────┘     │
                           │                           │
                           │  ┌──────────────────┐     │
                           │  │ ns: feat-auth     │     │
                           │  │  ...              │     │
                           │  └──────────────────┘     │
                           └──────────────────────────┘
```

### Key Design Decisions

1. **Isolated AWS account** — all ephemeral environments live in a dedicated `sandbox`
   AWS account (separate from dev/staging/prod). Mistakes cannot affect production.

2. **Kubernetes namespace isolation** — each environment gets its own namespace with
   NetworkPolicies that block cross-environment traffic.

3. **Shared infrastructure where safe** — VPC, EKS cluster, and IAM roles are shared
   across environments (Kubernetes isolation is sufficient). Databases are provisioned
   per-environment (data isolation required).

4. **TTL-based cleanup** — every environment has a maximum lifetime (default: 72 hours).
   This is enforced by a Lambda function that runs every 6 hours.

---

## Developer Workflow

### Provisioning (self-serve)

**Option 1: GitHub PR comment** (zero-friction):
```
# On any PR, comment:
/env create

# Argo CD App + Terraform environment will be provisioned within ~8 minutes.
# The IDP bot replies with:
#   ✅ Environment ready: https://feat-payment-v2.sandbox.clevertap.com
#   TTL: 72 hours (auto-destroy at 2024-01-18 14:30 UTC)
#   Extend: /env extend 24h
#   Destroy: /env destroy
```

**Option 2: GitHub Actions manual dispatch**:
```yaml
# .github/workflows/create-env.yml (in service repo)
on:
  workflow_dispatch:
    inputs:
      branch:
        description: Branch to deploy
        required: true
      ttl_hours:
        description: Environment lifetime in hours (max 168)
        default: "72"
```

**Option 3: Backstage (Service Catalog)**:
The Backstage developer portal exposes a "New Environment" wizard that validates
inputs and triggers the GitHub Actions workflow.

### Environment Lifecycle

```
create → ready → [extend] → expiring-warning (6h before) → auto-destroy
  │                                               │
  │                                    /env extend (max 3 extensions)
  │                                               │
  └──────────────────────────────────────────────┘
```

### What Gets Provisioned

Each environment gets:
| Resource | Config | Notes |
|----------|--------|-------|
| Kubernetes namespace | Isolated, with NetworkPolicy | EKS cluster is shared |
| RDS PostgreSQL | `t4g.small`, single-AZ | No Multi-AZ in sandbox |
| ElastiCache Redis | `cache.t4g.micro`, single node | |
| SQS queue(s) | Per service definition | Auto-named by environment ID |
| External DNS record | `<env-id>.sandbox.clevertap.com` | TTL deleted with env |
| TLS certificate | ACM wildcard `*.sandbox.clevertap.com` | Shared across envs |
| Kubernetes secrets | Via External Secrets Operator | Sandbox-scoped credentials |

---

## IDP Implementation

### Platform Components

```
IDP Bot (GitHub App)
    └── Listens for PR comments matching /env <command>
    └── Triggers GitHub Actions workflow

GitHub Actions Workflow (cicd/platform/create-env.yml)
    └── Validates input (quota, naming, branch exists)
    └── Calls Terraform workspace
    └── Updates DynamoDB (TTL registry)
    └── Posts result to PR

Terraform Module: modules/ephemeral-env/
    └── Creates: namespace, RDS, ElastiCache, SQS, DNS
    └── Tags everything with: environment-id, created-by, pr-number, ttl

DynamoDB: clevertap-env-registry
    └── PK: environment-id
    └── Attributes: owner, pr-number, ttl, created-at, resources
    └── TTL attribute: auto-expires after environment lifetime + 24h buffer

Lambda: env-cleanup-scheduler (runs every 6 hours)
    └── Scans DynamoDB for expired environments
    └── Calls GitHub Actions workflow to destroy
    └── Sends Slack notification to environment owner
```

### Terraform Module Structure

```hcl
# modules/ephemeral-env/main.tf
module "ephemeral_env" {
  source = "../../modules/ephemeral-env"

  environment_id = var.environment_id  # e.g., "feat-payment-v2-pr-142"
  owner          = var.owner           # GitHub username
  pr_number      = var.pr_number
  ttl_hours      = var.ttl_hours       # Default: 72

  # Service dependencies (declared in service's .env-config.yaml)
  services = {
    database = {
      engine  = "postgres"
      version = "15.4"
      size    = "t4g.small"
    }
    cache = {
      engine = "redis"
      size   = "cache.t4g.micro"
    }
    queues = ["campaign-events", "notification-delivery"]
  }
}
```

### Service Environment Contract (`.env-config.yaml`)

Each service declares its environment requirements in a file committed to the service repo:

```yaml
# event-ingestion/.env-config.yaml
# Declares what this service needs for an isolated ephemeral environment.
name: event-ingestion
dependencies:
  database:
    engine: postgres
    version: "15.4"
    size: t4g.small          # Always t4g.small in sandbox; never t3.xlarge
  cache:
    engine: redis
    size: cache.t4g.micro
  queues:
    - name: campaign-events
    - name: dead-letter-queue
environment:
  vars:
    LOG_LEVEL: debug          # Debug logging in sandbox
    KAFKA_ENABLED: "false"    # Use SQS in sandbox instead of Kafka
  secrets:
    # These secret paths will be created in sandbox Secrets Manager
    - /clevertap/sandbox/<env-id>/event-ingestion/db-password
    - /clevertap/sandbox/<env-id>/event-ingestion/redis-url
```

---

## Cost Governance

### Quotas and Guardrails

| Constraint | Value | Enforcement |
|------------|-------|-------------|
| Max active environments per team | 5 | IAM policy + DynamoDB quota check |
| Max environment lifetime | 168 hours (7 days) | Lambda cleanup enforces hard limit |
| Max environment extensions | 3 | Tracked in DynamoDB |
| Allowed instance sizes | `t4g.*` only | AWS Organizations SCP |
| No production instance types | `r5`, `m5`, etc. blocked | Organizations SCP |
| Max RDS storage | 50 GB | Terraform variable validation |

### AWS Organizations SCP for Sandbox Account

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowOnlySandboxInstanceTypes",
      "Effect": "Deny",
      "Action": ["rds:CreateDBInstance", "ec2:RunInstances"],
      "Resource": "*",
      "Condition": {
        "StringNotLike": {
          "rds:DatabaseClass": "db.t4g.*",
          "ec2:InstanceType": "t4g.*"
        }
      }
    },
    {
      "Sid": "RequireEnvironmentIdTag",
      "Effect": "Deny",
      "Action": ["rds:CreateDBInstance", "ec2:RunInstances", "elasticache:CreateCacheCluster"],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "us-east-1"
        },
        "Null": {
          "aws:RequestTag/environment-id": "true"
        }
      }
    }
  ]
}
```

### Budget Alerting

Each team has a sandbox AWS Budget:
```
Budget: $500/month per team
Alerts at: 50% ($250), 80% ($400), 100% ($500)
Action at 100%: Notify team lead; auto-destroy oldest 3 environments
```

---

## Security Guardrails

### Isolation

1. **Network isolation**: NetworkPolicy blocks all cross-namespace traffic by default
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: deny-cross-namespace
     namespace: feat-payment-v2
   spec:
     podSelector: {}
     ingress:
       - from:
           - namespaceSelector:
               matchLabels:
                 kubernetes.io/metadata.name: feat-payment-v2
   ```

2. **IAM isolation**: Each environment gets a scoped IRSA role that can only read
   `/clevertap/sandbox/<env-id>/` secrets. Cross-environment secret access is blocked
   by IAM policy conditions.

3. **No production data**: Sandbox RDS instances are initialized with anonymized
   synthetic data (generated via `tools/generate-test-data.sh`). Production data
   never flows into sandbox environments.

4. **Automatic credential rotation**: Sandbox database passwords are generated
   randomly at environment creation and stored in Secrets Manager. No human ever
   sees them.

### What Teams CAN'T Do

- Access production secrets or databases (IAM, SCP)
- Create instances larger than t4g (SCP)
- Keep environments running beyond 7 days without explicit approval
- Disable tagging on resources (SCP)
- Modify the VPC or shared networking (IAM)

---

## Cleanup Automation

The `env-cleanup-scheduler` Lambda runs every 6 hours:

```python
# Pseudocode for cleanup scheduler
def handler(event, context):
    expired_envs = dynamodb.scan(
        FilterExpression="ttl < :now AND #status = :active",
        ExpressionAttributeValues={
            ":now": int(time.time()),
            ":active": "active"
        }
    )

    for env in expired_envs['Items']:
        # Notify owner 6 hours before destruction
        if env['ttl'] - time.time() < 21600 and not env.get('warned'):
            slack.send(
                channel=f"@{env['owner']}",
                message=f"Environment {env['id']} expires in 6 hours. /env extend to keep it."
            )
            dynamodb.update_item(Key={'id': env['id']}, UpdateExpression="SET warned = :true")
        elif env['ttl'] < time.time():
            trigger_destroy_workflow(env['id'], env['pr_number'])
            dynamodb.update_item(Key={'id': env['id']}, UpdateExpression="SET #status = :destroying")
```

---

## Measuring IDP Health

| Metric | Target | How Measured |
|--------|--------|--------------|
| Environment provisioning time | < 10 minutes | GitHub Actions run duration |
| Environment provisioning success rate | > 95% | Failed workflow runs / total |
| Mean time to self-serve | < 1 day | Ticket age (Jira) for env requests |
| Sandbox spend per team | Tracked, not capped | AWS Cost Explorer tags |
| Environments destroyed by TTL vs manually | < 30% by TTL | DynamoDB + Lambda metrics |
| Environments older than 48h | < 20% of active | DynamoDB query |
