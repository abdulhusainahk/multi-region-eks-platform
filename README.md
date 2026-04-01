# Multi Region Cloud Platform

> **Role**: Staff DevOps Engineer  
> **Assessment Sections**: Infrastructure Architecture & IaC (Section 1)

---

## Repository Structure

```
.
├── modules/
│   ├── vpc/              # Reusable multi-region VPC module
│   │   ├── main.tf       # VPC, subnets, IGW, NAT GWs, route tables
│   │   ├── flow_logs.tf  # VPC Flow Logs → S3 with lifecycle policies
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── eks/              # Reusable EKS cluster module
│       ├── main.tf       # EKS cluster, node groups, security groups, KMS
│       ├── irsa.tf       # IRSA (IAM Roles for Service Accounts) via OIDC
│       ├── addons.tf     # Managed cluster add-ons (VPC CNI, CoreDNS, etc.)
│       ├── variables.tf
│       └── outputs.tf
├── environments/
│   ├── dev/              # Development (us-east-1, single NAT GW, Spot nodes)
│   ├── staging/          # Staging (us-east-1, HA NAT GWs, mixed nodes)
│   └── prod/
│       ├── us-east-1/    # Primary production region
│       ├── ap-south-1/   # Secondary production region (Mumbai)
│       └── eu-west-1/    # EU production (GDPR-isolated, separate AWS account)
├── bootstrap/            # One-time S3/DynamoDB backend provisioning
├── docs/
│   ├── state-management.md   # Section 1b: State & Drift Management
│   └── eu-data-residency.md  # Section 1c: EU Data Residency Architecture
└── .github/workflows/
    ├── terraform.yml          # CI/CD pipeline with promotion gates
    └── drift-detection.yml    # Daily drift detection + GitHub Issue alerts
```

---

## Section 1a: Module Design Decisions

### VPC Module

#### Features
- **Three subnet tiers** per AZ: public (IGW), private (NAT), intra/database (no internet route)
- **Kubernetes-aware tags** on subnets: `kubernetes.io/role/elb` (public) and `kubernetes.io/role/internal-elb` (private) for ALB auto-discovery
- **Per-AZ NAT Gateways** in prod for fault isolation; configurable `single_nat_gateway = true` for dev cost savings
- **Default security group** set to deny-all (overrides AWS's permissive default)
- **Transit Gateway attachment** with per-route-table association and propagation
- **VPC Flow Logs** to S3 in Parquet format with Hive-compatible partitioning for efficient Athena queries. Lifecycle: Standard → Standard-IA → Glacier IR → Expire

#### Transit Gateway vs. VPC Peering

| | Transit Gateway | VPC Peering |
|-|-----------------|-------------|
| **Scalability** | Hub-and-spoke; O(1) new connections | Full mesh; O(n²) connections |
| **Routing** | Centralized route tables, easy propagation | Per-peering route table entries |
| **Cost** | ~$0.05/GB + attachment fee | ~$0.01/GB (lower per-GB) |
| **Transitive routing** | Yes (via TGW) | No |
| **Multi-region** | Works with Inter-Region TGW Peering | Each pair needs a peering connection |

**Decision: Transit Gateway.** With 3+ regions (us-east-1, ap-south-1, eu-west-1) and potentially more to come, TGW scales to N regions with N attachments vs. N² peering connections. The centralized route table also makes it straightforward to **exclude EU** from cross-region routing (just don't create an attachment from the EU VPC), which is critical for data residency.

---

### EKS Module

#### Security Hardening
- **Private API server endpoint** (`cluster_endpoint_public_access = false` in prod/staging)
- **KMS encryption** for Kubernetes Secrets at rest
- **IMDSv2 enforced** on all nodes (`http_tokens = "required"`) — prevents SSRF-based credential theft from pods
- **No public IPs** on nodes (`associate_public_ip_address = false`)
- **SSM agent** on nodes — enables shell access without opening SSH port 22
- **All control-plane log types** enabled (api, audit, authenticator, controllerManager, scheduler)

#### IRSA (IAM Roles for Service Accounts)

IRSA is the AWS-recommended approach for pod-level AWS permissions. It avoids the "give all pods on a node the same IAM role" problem by scoping permissions to a specific Kubernetes service account.

How it works:
1. The OIDC provider maps pod identity tokens to IAM role assumptions
2. Each application declares which IAM role it needs in its `ServiceAccount` annotation
3. The token audience (`sts.amazonaws.com`) and subject (`system:serviceaccount:<ns>:<sa>`) are validated to prevent confused-deputy attacks

The module pre-creates IRSA roles for VPC CNI and EBS CSI Driver (which need AWS API access). Application-level IRSA roles are passed via `var.irsa_roles`.

#### Mixed Instance Node Groups

CleverTap handles 10-50x traffic spikes. The node group strategy is:

| Pool | Instances | On-Demand % | Purpose |
|------|-----------|-------------|---------|
| `on-demand-critical` | m6i.2xlarge, m6a.2xlarge | 100% | Core services, databases, metrics |
| `mixed-event-processing` | m6i.xlarge + 5 others | 25% base + 25% above | Event ingestion, campaign delivery |
| `spot-batch` | c6i.2xlarge + 3 others | 0% | Analytics, ML training, backfill |

**Spot eviction strategy:**
- `price-capacity-optimized` allocation strategy (AWS recommends this over `lowest-price` for production)
- 6+ instance types per Spot pool — diversification reduces the chance of mass eviction
- PodDisruptionBudgets (PDBs) set to `minAvailable: 2` for stateful services
- Cluster Autoscaler `--balance-similar-node-groups` flag balances across instance types
- Spot interruption handler (e.g., [AWS Node Termination Handler](https://github.com/aws/aws-node-termination-handler)) drains nodes 2 minutes before interruption
- Workloads that tolerate Spot carry the `spot: "true"` taint; only `NO_SCHEDULE` tolerating pods land on Spot nodes

#### Cluster Add-ons (Managed via Terraform)

| Add-on | Purpose | IRSA Role |
|--------|---------|-----------|
| `vpc-cni` | Pod networking, prefix delegation | `aws-node` SA → `AmazonEKS_CNI_Policy` |
| `coredns` | DNS resolution within cluster | — |
| `kube-proxy` | Service iptables rules | — |
| `aws-ebs-csi-driver` | PersistentVolume provisioning | `ebs-csi-controller-sa` → `AmazonEBSCSIDriverPolicy` |

VPC CNI is configured with **prefix delegation** (`ENABLE_PREFIX_DELEGATION = true`) which allows each node to host many more pods (up to 110 per node for large instances vs. the default ~30).

---

## Section 1b: State & Drift Management

See **[docs/state-management.md](docs/state-management.md)** for the full design.

**Summary:**
- One S3 bucket + DynamoDB lock table per environment (dev, staging, prod, prod-eu)
- State key structure: `{env}/{region}/terraform.tfstate`
- EU state in dedicated bucket in eu-west-1 — never leaves the EU
- Teams use remote state data sources (not direct module calls) to share outputs
- Drift detection via daily `terraform plan -detailed-exitcode` in GitHub Actions
- Drift alerts posted as GitHub Issues, closed automatically when resolved

---

## Section 1c: EU Data Residency

See **[docs/eu-data-residency.md](docs/eu-data-residency.md)** for the full design.

**Summary:**
- Dedicated `clevertap-prod-eu` AWS account with Organizations SCP blocking all non-eu-west-1 data operations
- No Transit Gateway connection to non-EU regions — data has no network path to leave the EU
- KMS key policy denies use from outside eu-west-1
- IRSA roles scoped to eu-west-1 via condition keys
- Single CI/CD pipeline with **separate OIDC credentials** for the EU account
- Terraform provider uses `allowed_account_ids` to prevent accidental cross-account applies

---

## Getting Started

### Prerequisites

- Terraform >= 1.5.0
- AWS CLI configured with appropriate profiles
- An AWS account per environment

### Bootstrap (one-time per environment)

```bash
cd bootstrap/
terraform init
terraform apply \
  -var="environment=dev" \
  -var="region=us-east-1"
```

This creates the S3 state bucket, DynamoDB lock table, and KMS key.

### Deploy Dev Environment

```bash
cd environments/dev/

# Initialize with remote backend (bucket created in bootstrap step)
terraform init \
  -backend-config="bucket=clevertap-terraform-state-dev" \
  -backend-config="key=dev/us-east-1/terraform.tfstate" \
  -backend-config="region=us-east-1"

# Plan
terraform plan -out=tfplan

# Apply
terraform apply tfplan
```

### Deploy Prod (via CI/CD)

Prod deployments are **only** performed via GitHub Actions:

1. Merge PR to `main` → auto-applies to **dev**
2. CI waits for manual approval → applies to **staging**
3. CI waits for 2-reviewer approval → applies to **prod** (sequential: us-east-1 → ap-south-1 → eu-west-1)

### Check for Drift

```bash
cd environments/prod/us-east-1/
terraform init
terraform plan -detailed-exitcode
# Exit 0: no drift
# Exit 2: drift detected — review output and remediate
```

---

## Cost Optimisation Notes

The current $420K/month bill can be reduced by 25–30% through:

| Initiative | Est. Saving | Effort |
|-----------|------------|--------|
| Spot nodes for batch/analytics workloads | ~$40K/month | Low — already in this IaC |
| Right-size On-Demand pools (Compute Optimizer recommendations) | ~$25K/month | Medium |
| NAT Gateway consolidation in dev/staging | ~$5K/month | Low |
| S3 Intelligent Tiering for flow logs and object storage | ~$10K/month | Low |
| Reserved Instances for On-Demand baseline (1-year no-upfront) | ~$45K/month | Low |
| VPC endpoint for S3/DynamoDB (avoid NAT GW data charges) | ~$8K/month | Low |
| **Total** | **~$133K/month (~32%)** | |

---

## Security Summary

| Control | Implementation |
|---------|---------------|
| Private EKS API | `endpoint_public_access = false` in staging/prod |
| Secrets encryption | KMS key with rotation, applied to EKS + Terraform state |
| IMDSv2 | Enforced on all nodes via Launch Template |
| Pod permissions | IRSA (per-service-account IAM roles, not node instance profiles) |
| EU data residency | AWS Organizations SCP + account isolation + no TGW cross-region |
| Secrets in CI/CD | GitHub OIDC (no long-lived keys), no hardcoded secrets in YAML |
| State security | Encrypted, versioned, public-access-blocked S3; TLS-only bucket policy |
| Flow logs | All VPC traffic logged in Parquet to S3, 1-year retention |
| Drift detection | Daily automated `terraform plan`, alerts via GitHub Issues |

---

## Section 2: Reliability, Observability & Incident Response

### Repository Structure (Section 2)

```
├── observability/
│   ├── prometheus/
│   │   ├── rules/
│   │   │   └── slo-event-ingestion.yaml    # SLO burn-rate alert rules (multi-window)
│   │   └── recording-rules/
│   │       └── event-ingestion.yaml        # Pre-aggregation recording rules
│   ├── grafana/
│   │   └── dashboards/
│   │       └── event-ingestion.json        # Service overview dashboard (SLO-based)
│   ├── otel-collector/
│   │   └── config.yaml                     # OTEL Collector DaemonSet configuration
│   └── terraform/                          # Observability stack Terraform module
│       ├── main.tf                         # Prometheus, Loki, Tempo, Grafana, OTEL
│       ├── variables.tf
│       ├── outputs.tf
│       ├── values/                         # Helm values templates
│       └── templates/                      # Alertmanager config template
├── runbooks/
│   ├── pod-crash-looping.md                # KubePodCrashLooping structured runbook
│   ├── scripts/
│   │   └── triage.sh                       # Automated triage helper script
│   └── templates/
│       ├── incident-comms.md               # Incident communication templates
│       └── pir-template.md                 # Post-Incident Review template
└── docs/
    ├── observability-architecture.md       # Section 2a: Four-pillar observability design
    ├── alert-noise-reduction.md            # Section 2c: Systematic alert noise reduction
    ├── state-management.md                 # Section 1b: Terraform state management
    └── eu-data-residency.md                # Section 1c: GDPR data residency
```

---

## Section 2a: Observability Architecture

See **[docs/observability-architecture.md](docs/observability-architecture.md)** for the full design.

**Four-pillar summary:**

| Pillar | Tools | Storage | Key Design Decision |
|--------|-------|---------|---------------------|
| **Metrics** | Prometheus + Thanos + Grafana | S3 (long-term) | Cardinality budget per service; VPA for Prometheus |
| **Logs** | Fluent Bit + Grafana Loki | S3 (chunks) | Label-based indexing prevents cardinality explosion; 10x cheaper than Elasticsearch |
| **Traces** | OTEL SDK + Grafana Tempo | S3 | Tail-based sampling: 100% errors, 1% success traces |
| **Events** | K8s events + CloudWatch + Grafana annotations | CloudWatch + S3 | Deploy annotations on all dashboards for instant correlation |

**SLO-based alerting** (replaces threshold alerts):
- Multi-window burn rate alerts: 1h/5m (P1) and 6h/30m (P2)
- Eliminates 60%+ of noisy auto-resolving alerts
- See `observability/prometheus/rules/slo-event-ingestion.yaml`

---

## Section 2b: Runbook — KubePodCrashLooping

See **[runbooks/pod-crash-looping.md](runbooks/pod-crash-looping.md)** for the full runbook.

**Quick reference for on-call:**
```bash
# Run automated triage (Steps 1.1–1.7)
bash runbooks/scripts/triage.sh production event-ingestion

# Rollback (most common fix)
kubectl rollout undo deployment/event-ingestion -n production

# Scale out (OOMKilled)
kubectl scale deployment event-ingestion -n production --replicas=12
```

Templates: [incident-comms.md](runbooks/templates/incident-comms.md) | [pir-template.md](runbooks/templates/pir-template.md)

---

## Section 2c: Alert Noise Reduction

See **[docs/alert-noise-reduction.md](docs/alert-noise-reduction.md)** for the systematic approach.

**Target outcomes after 30-day remediation sprint:**

| Metric | Before | Target |
|--------|--------|--------|
| Alerts/day | 200 | < 40 (−80%) |
| Auto-resolve rate | 60% | < 10% |
| Alert-to-incident ratio | 5% | > 30% |
| MTTA (P1) | ~8 min | < 3 min |

---

## Section 3: Developer Platform, CI/CD & Engineering Velocity

### Repository Structure (Section 3)

```
├── .github/workflows/
│   └── microservice-cicd.yml         # Full CI/CD pipeline (PR + staging + prod canary)
├── cicd/
│   ├── helm/microservice/            # Generic Helm chart for EKS microservices
│   │   ├── Chart.yaml
│   │   ├── values.yaml               # Default values (no secrets)
│   │   ├── values-staging.yaml       # Staging overrides
│   │   ├── values-prod.yaml          # Production overrides (Argo Rollouts enabled)
│   │   └── templates/
│   │       ├── deployment.yaml       # Standard Deployment (staging/dev)
│   │       ├── rollout.yaml          # Argo Rollouts canary (production)
│   │       ├── analysis-template.yaml # Prometheus-based canary analysis
│   │       ├── external-secret.yaml  # External Secrets Operator integration
│   │       ├── hpa.yaml              # Horizontal Pod Autoscaler
│   │       ├── pdb.yaml              # Pod Disruption Budget
│   │       ├── service.yaml          # Services (stable + canary for rollouts)
│   │       └── serviceaccount.yaml   # IRSA-enabled ServiceAccount
│   └── smoke-tests/
│       └── smoke-test.sh             # Staging smoke test script
└── docs/
    ├── cicd-pipeline.md              # Production canary strategy + secret management
    └── internal-developer-platform.md # Self-serve IDP design
```

---

## Section 3a: CI/CD Pipeline

See **[docs/cicd-pipeline.md](docs/cicd-pipeline.md)** and **[.github/workflows/microservice-cicd.yml](.github/workflows/microservice-cicd.yml)**

**Pipeline stages:**

| Stage | Jobs | Trigger |
|-------|------|---------|
| PR | lint → unit-tests → build-push → sast-scan (Trivy) | Every pull request |
| Staging | deploy-staging (Helm) → smoke-tests → approve-staging | Push to main |
| Production | deploy-prod-canary (Argo Rollouts 10%→50%→100%) | After manual approval |

**Key features:**
- Commit SHA image tags — same artifact promoted through all stages (no rebuilds)
- Trivy SAST: blocks on CRITICAL CVEs; SARIF uploaded to GitHub Security tab
- Canary auto-rollback if error rate > 1% or p99 latency > 500ms (Prometheus-based)
- No secrets in YAML: GitHub OIDC → AWS IAM; secrets via External Secrets Operator + AWS Secrets Manager

---

## Section 3b: Internal Developer Platform

See **[docs/internal-developer-platform.md](docs/internal-developer-platform.md)**

Engineers can provision isolated feature environments via:
- `/env create` PR comment → 8-minute provisioning
- Resources: RDS (t4g.small), ElastiCache (t4g.micro), SQS, Kubernetes namespace
- Cost guardrails: t4g-only SCP, 5 envs/team quota, 72h TTL (max 7 days)
- Auto-cleanup Lambda runs every 6 hours; warns 6 hours before destruction

---

## Section 4: Cost Engineering

### Repository Structure (Section 4)

```
├── modules/
│   └── tagging/                      # Reusable tag standardization module
│       ├── main.tf
│       ├── variables.tf              # Validated: team, service, env, cost-center, owner
│       └── outputs.tf               # tags (map), name_prefix
└── docs/
    ├── cost-reduction-plan.md        # 90-day plan: $105K–$140K/month savings
    └── finops-process.md             # Tagging strategy, showback, alerts, Infracost
```

---

## Section 4a: 90-Day Cost Reduction Plan

See **[docs/cost-reduction-plan.md](docs/cost-reduction-plan.md)**

Starting at $420K/month, target 25–30% reduction ($105K–$126K):

| Phase | Initiative | Savings | Effort |
|-------|-----------|---------|--------|
| Week 1–2 | VPA right-sizing, delete unused, S3 Intelligent-Tiering, Spot for batch | $42K–$61K | Low |
| Month 1–2 | Compute Savings Plans, RDS RIs, right-sizing | $36K–$48K | Low–Med |
| Month 2–3 | Inter-region transfer reduction, analytics→Athena, Graviton3 | $47K–$68K | Med–High |

---

## Section 4b: FinOps Process

See **[docs/finops-process.md](docs/finops-process.md)**

**Tagging module** (`modules/tagging/`) — validated required tags: `team`, `service`, `environment`, `cost-center`, `owner`. SCP enforces tagging at resource creation.

**Showback**: CUR → S3 → Athena → QuickSight (team dashboards, unit economics: cost/billion events)

**Alerting thresholds**: Cost Anomaly Detection (>20% spike AND >$500/day) + Budget alerts at 50%/80%/100%/120% per team

**Infracost in CI**: Cost estimate posted as PR comment for every Terraform change — engineers see infrastructure cost before it's applied.
"# clevertap" 
