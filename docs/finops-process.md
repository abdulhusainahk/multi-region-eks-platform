# Section 4b: FinOps Process Design

## Goal

Transform AWS cost from an invisible infrastructure tax into a **visible, owned, and
optimized** engineering metric. Engineers who can see their team's spend make better
tradeoff decisions; engineers who can't see it don't optimize.

---

## 1. Tagging Strategy

Tags are the foundation of cost attribution. A tag that isn't applied 100% of the time
provides only partial visibility — which is worse than no visibility (creates misleading reports).

### Mandatory Tag Set

| Tag Key | Example Values | Purpose | Enforced By |
|---------|----------------|---------|-------------|
| `team` | `platform-sre`, `campaign-delivery`, `analytics` | Cost attribution to team | SCP + Terraform |
| `service` | `event-ingestion`, `campaign-api` | Service-level cost breakdown | Terraform module |
| `environment` | `prod`, `staging`, `dev`, `sandbox` | Env-level cost isolation | Terraform module |
| `cost-center` | `CC-1001`, `CC-2003` | Finance team chargeback | SCP |
| `managed-by` | `terraform`, `helm`, `manual` | Operational audit | Terraform provider default |
| `owner` | `john.smith@clevertap.com` | Contact for anomaly alerts | SCP |

### Tag Enforcement

**AWS Organizations SCP** (enforced at account level — cannot be bypassed):
```json
{
  "Sid": "RequireMandatoryTags",
  "Effect": "Deny",
  "Action": [
    "ec2:RunInstances",
    "rds:CreateDBInstance",
    "elasticache:CreateCacheCluster",
    "eks:CreateNodegroup",
    "s3:CreateBucket",
    "lambda:CreateFunction"
  ],
  "Resource": "*",
  "Condition": {
    "Null": {
      "aws:RequestTag/team": "true",
      "aws:RequestTag/environment": "true",
      "aws:RequestTag/cost-center": "true"
    }
  }
}
```

**Terraform module enforcement** — every shared module includes tags as required variables:
```hcl
# modules/eks/variables.tf (excerpt)
variable "tags" {
  type = object({
    team        = string
    service     = string
    environment = string
    cost-center = string
    owner       = string
  })
  description = "Mandatory resource tags. All keys required."
  validation {
    condition     = length(var.tags.team) > 0 && length(var.tags.cost-center) > 0
    error_message = "team and cost-center tags are required."
  }
}

# modules/eks/main.tf
locals {
  mandatory_tags = merge(var.tags, {
    managed-by = "terraform"
    module     = "eks"
  })
}
```

**Tagging compliance reporting** — weekly automated report via AWS Config:
```hcl
# In Terraform: AWS Config rule to detect untagged resources
resource "aws_config_config_rule" "required_tags" {
  name = "required-tags"
  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }
  input_parameters = jsonencode({
    tag1Key = "team"
    tag2Key = "environment"
    tag3Key = "cost-center"
  })
}
```

---

## 2. Terraform Tagging Module

See [`modules/tagging/`](../modules/tagging/) for the reusable module that standardizes
tag generation across all environments.

```hcl
# Usage in any environment:
module "tags" {
  source       = "../../modules/tagging"
  team         = "platform-sre"
  service      = "event-ingestion"
  environment  = "prod"
  cost_center  = "CC-1001"
  owner        = "sre@clevertap.com"
}

# Then pass to any resource or module:
resource "aws_instance" "example" {
  tags = module.tags.tags
}
```

---

## 3. Showback Model

Showback means **teams can see** their cost allocation but are not billed internally.
It is a precursor to chargeback and is lower-friction to implement first.

### Architecture

```
AWS Cost & Usage Report (CUR)
    │ (hourly export to S3)
    ▼
S3 Bucket (cur-data/)
    │
    ▼
AWS Glue (ETL: normalize, join with service catalog)
    │
    ▼
Amazon Athena (ad-hoc queries)
    │
    ▼
Amazon QuickSight (dashboards, team-level views)
    │
    ├── Team dashboards (each team sees only their costs)
    ├── FinOps weekly digest (all teams, leadership view)
    └── Anomaly alerts (via CloudWatch + SNS → Slack)
```

### QuickSight Dashboard Hierarchy

**Level 1: CTO / VP Engineering view**
- Total spend by environment (prod vs staging vs dev vs sandbox)
- Month-over-month growth rate
- Cost per billion events processed (unit economics)
- Top-10 cost drivers (teams, services)

**Level 2: Engineering Manager view** (one per team)
- Team's total spend this month vs last month
- Breakdown: compute / database / storage / transfer
- Top-3 most expensive services in the team
- Budget vs actual (traffic light: green/yellow/red)

**Level 3: Engineer view** (service-level, accessible to all)
- Cost per service (daily/weekly/monthly)
- Cost breakdown: EC2 / RDS / ElastiCache / S3 / data transfer
- Trend over last 90 days
- "What changed?" correlation with deployment events (overlaid)

### Unit Economics Metrics

Teams are evaluated not just on absolute spend but on **cost efficiency**:

| Metric | Formula | Target |
|--------|---------|--------|
| Cost per billion events | total_compute_cost / events_processed_billions | Tracked, improving QoQ |
| Cost per active customer | total_cost / active_customers | < $0.10/customer/month |
| Compute utilization | CPU and memory actually used / billed | > 65% |
| Storage efficiency | hot data / total data | < 40% in frequent-access tier |

---

## 4. Chargeback Model (Phase 2, after 3 months of showback)

After teams are familiar with seeing their costs, move to chargeback:
- Teams are allocated their cost in internal P&L statements
- Engineering Managers have quarterly budget targets
- Overage > 20% requires a written explanation to VP Engineering

Chargeback creates incentives to right-size and clean up, but should only be introduced
after teams have had time to understand and optimize their spend.

---

## 5. Alerting Thresholds

### AWS Cost Anomaly Detection (fully managed, no setup cost)

```hcl
# Terraform: configure anomaly detection for each team
resource "aws_ce_anomaly_monitor" "team" {
  for_each      = var.teams
  name          = "${each.key}-cost-anomaly-monitor"
  monitor_type  = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "team" {
  for_each  = var.teams
  name      = "${each.key}-anomaly-subscription"
  threshold_expression {
    and {
      dimension {
        key           = "ANOMALY_TOTAL_IMPACT_PERCENTAGE"
        values        = ["20"]        # Alert if cost is 20%+ above expected
        match_options = ["GREATER_THAN_OR_EQUAL"]
      }
      dimension {
        key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
        values        = ["500"]       # And at least $500/day in absolute terms
        match_options = ["GREATER_THAN_OR_EQUAL"]
      }
    }
  }
  frequency  = "DAILY"
  monitor_arn_list = [aws_ce_anomaly_monitor.team[each.key].arn]
  subscriber {
    type    = "SNS"
    address = aws_sns_topic.cost_alerts[each.key].arn
  }
}
```

### Budget Alerts per Team

| Threshold | Alert Type | Recipient | Action |
|-----------|-----------|-----------|--------|
| 50% of monthly budget | Informational | Slack #finops-alerts | No action required |
| 80% of monthly budget | Warning | Slack + team lead email | Review spend, identify savings |
| 100% of monthly budget | Critical | PagerDuty (low priority) + EM | Approval required for new resources |
| 120% of monthly budget | Escalation | EM + VP Engineering | Written explanation required |

```hcl
resource "aws_budgets_budget" "team" {
  for_each    = var.teams
  name        = "${each.key}-monthly-budget"
  budget_type = "COST"
  limit_amount = each.value.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name = "TagKeyValue"
    values = ["team$${each.key}"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [each.value.team_lead_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_arns        = [aws_sns_topic.cost_alerts[each.key].arn]
  }
}
```

---

## 6. Weekly FinOps Review Process

Every Monday, an automated report is generated and sent to #finops Slack channel:

**Report Contents**:
1. Total spend last week vs week prior (% change)
2. Top-5 cost increases by service (absolute $)
3. Top-5 waste signals (idle resources, low utilization)
4. Current error budget vs budget (are we on track for the month?)
5. Action items from last week (resolved/not resolved)

**Monthly FinOps Review** (30 min, Engineering Leads):
1. Review month-over-month trend
2. Review savings plan coverage vs on-demand spend
3. Identify the next $10,000/month optimization opportunity
4. Set targets for next month

---

## 7. Engineer Ownership Model

**The goal**: the engineer who writes the code owns the cost of running it.

| Practice | Implementation |
|----------|----------------|
| Cost estimates in PRs | GitHub Actions step adds cost estimate comment on every Terraform PR (using `infracost`) |
| Cost badges in README | Each service's README shows current monthly cost (updated by CI) |
| "Cost of deploy" metric | Dashboard shows cost impact of each deployment (before/after) |
| FinOps champions | One engineer per team is the FinOps champion (rotates quarterly) |
| Cost optimization OKR | Each team includes one cost optimization OKR per quarter |

### Infracost in CI (cost estimate on every Terraform PR)

```yaml
# Add to .github/workflows/terraform.yml
- name: Estimate cost of infrastructure changes
  uses: infracost/actions/setup@v2
  with:
    api-key: ${{ secrets.INFRACOST_API_KEY }}

- name: Generate cost estimate
  run: |
    infracost diff \
      --path environments/${{ matrix.env }} \
      --format json \
      --out-file /tmp/infracost.json

- name: Post cost estimate to PR
  uses: infracost/actions/comment@v2
  with:
    path: /tmp/infracost.json
    behavior: update
```

This shows engineers exactly how much a new RDS instance or EKS node group will cost
**before** it's applied — turning infrastructure cost into a first-class code review concern.
