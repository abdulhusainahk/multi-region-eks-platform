# Section 4a: 90-Day Cost Reduction Plan

## Starting Point

| Category | Monthly Spend | Share of Bill |
|----------|--------------|---------------|
| EKS on EC2 (compute) | ~$180,000 | 43% |
| RDS (PostgreSQL, MySQL) | ~$75,000 | 18% |
| ElastiCache (Redis) | ~$42,000 | 10% |
| S3 (storage + requests) | ~$35,000 | 8% |
| Data transfer (inter-region) | ~$55,000 | 13% |
| Other (CloudWatch, ECR, etc.) | ~$33,000 | 8% |
| **Total** | **$420,000** | **100%** |

**Target**: 25–30% savings = **$105,000–$126,000/month**

---

## Week 1–2: Quick Wins (Zero Risk, Low Effort)

### QW-1: Right-size EKS node groups with Karpenter (immediate)
**Savings**: $18,000–$25,000/month (10–14%)
**Effort**: Low — configuration change only
**Risk**: Low — Karpenter is already provisioning new nodes; this tunes the provisioner

**Problem**: Karpenter is launching nodes based on requested resources, but pods have
overprovisioned CPU/memory requests (set months ago and never reviewed).

**Action**:
```bash
# Install VPA in recommendation-only mode (no auto-apply yet)
kubectl apply -f https://github.com/kubernetes/autoscaler/releases/latest/download/vertical-pod-autoscaler.yaml

# After 72 hours of data collection, generate recommendations
kubectl get vpa -n production -o json | jq '.items[] | {
  name: .metadata.name,
  recommended_cpu: .status.recommendation.containerRecommendations[].target.cpu,
  recommended_memory: .status.recommendation.containerRecommendations[].target.memory,
  current_cpu: .spec.resourcePolicy.containerPolicies[].maxAllowed.cpu
}'
```

Teams apply VPA recommendations to their Helm values within 2 weeks.
Expected: 30–40% over-provisioned CPU/memory → 30% compute cost reduction.

### QW-2: Delete unused/orphaned resources
**Savings**: $5,000–$8,000/month (1–2%)
**Effort**: Low — automated discovery + manual review
**Risk**: Low — only delete after confirming unused

**Find unused resources**:
```bash
# EBS volumes not attached to any instance
aws ec2 describe-volumes \
  --filters Name=status,Values=available \
  --query 'Volumes[*].[VolumeId,Size,CreateTime,Tags]' \
  --output table

# RDS snapshots older than 90 days (automated snapshots, not manual)
aws rds describe-db-snapshots \
  --query 'DBSnapshots[?SnapshotType==`automated` && SnapshotCreateTime<=`2023-10-01`].[DBSnapshotIdentifier,AllocatedStorage]'

# Unattached Elastic IPs (charged at $0.005/hour when not attached)
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null]'

# Load balancers with no healthy targets
aws elbv2 describe-target-groups \
  --query 'TargetGroups[?HealthyHostCount==`0`]'
```

### QW-3: Enable S3 Intelligent-Tiering for existing buckets
**Savings**: $4,000–$6,000/month (1–1.5%)
**Effort**: Low — one-time Terraform change per bucket
**Risk**: None — Intelligent-Tiering moves objects automatically; no retrieval cost for Frequent/Infrequent tiers

```hcl
# In modules/s3-bucket/main.tf (apply to all non-critical buckets)
resource "aws_s3_bucket_intelligent_tiering_configuration" "default" {
  bucket = aws_s3_bucket.this.id
  name   = "entire-bucket"
  tiering {
    access_tier = "DEEP_ARCHIVE_ACCESS"
    days        = 180
  }
  tiering {
    access_tier = "ARCHIVE_ACCESS"
    days        = 90
  }
}
```

### QW-4: Enable EC2 Spot for Karpenter batch/non-critical workloads
**Savings**: $15,000–$22,000/month (4–5%)
**Effort**: Low — Karpenter NodePool configuration change
**Risk**: Low — affects only batch/analytics workloads, not event-ingestion critical path

```yaml
# In modules/eks/karpenter-nodepools.tf
# Existing: On-Demand for all workloads
# Change: Spot for analytics, batch, and dev/staging namespaces
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: spot-batch
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]  # 70% savings vs On-Demand
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["m5.xlarge", "m5.2xlarge", "m4.xlarge", "m5a.xlarge"]  # Multiple types = better spot availability
      nodeClassRef:
        name: default
  limits:
    cpu: "200"
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
```

**Week 1–2 Total Estimated Savings**: **$42,000–$61,000/month** (10–15%)

---

## Month 1–2: Right-Sizing and Commitment Strategy

### M1-1: EC2 Compute Savings Plans (1-year, no-upfront)
**Savings**: $28,000–$35,000/month (7–8%)
**Effort**: Low — purchase decision, no code change
**Risk**: None — Savings Plans apply automatically to matching usage

**When to use Compute Savings Plans vs. Reserved Instances:**

| Criterion | Compute Savings Plans | Reserved Instances |
|-----------|----------------------|-------------------|
| Workload type | Flexible; any EC2, Fargate, Lambda | Specific instance family/region |
| Flexibility | Switch instance families, regions, sizes | Locked to instance family in 1 region |
| Savings vs On-Demand | ~66% (1yr, no upfront) | ~72% (1yr, no upfront) for same family |
| **Best for** | EKS (instance types change frequently due to Karpenter) | RDS (instance type is stable; rarely changes) |
| **CleverTap recommendation** | ✅ Use for EKS/EC2 compute | ✅ Use for RDS |

**Strategy**:
1. **Baseline**: Analyze 3 months of usage to determine stable baseline consumption
2. **Buy**: Purchase Compute Savings Plans to cover 70% of EC2 baseline (leave 30% for On-Demand/Spot flexibility)
3. **Review**: Quarterly review to adjust commitment as workloads grow

```bash
# AWS CLI: get Savings Plans recommendations
aws savingsplans get-savings-plans-purchase-recommendation \
  --savings-plans-type COMPUTE_SP \
  --term-in-years ONE_YEAR \
  --payment-option NO_UPFRONT \
  --lookback-period-in-days SIXTY_DAYS
```

### M1-2: RDS Reserved Instances (1-year, no-upfront)
**Savings**: $18,000–$22,000/month (4–5%)
**Effort**: Low — purchase decision, 30-minute console action
**Risk**: None — RIs apply to running instances automatically

**Analysis**: RDS instances are stable (same type for 12+ months). 1-year RIs save ~40%
vs On-Demand. Note: DO NOT buy 3-year RIs — instance types will likely change as workload
grows (e.g., Aurora serverless v2 migration).

### M1-3: Right-size RDS instances
**Savings**: $8,000–$12,000/month (2–3%)
**Effort**: Medium — requires testing and coordination with app teams
**Risk**: Medium — incorrect sizing causes latency spikes

**Approach**:
1. Enable Enhanced Monitoring and Performance Insights (free for 7 days, $0.02/hour beyond)
2. Identify instances where CPU utilization < 20% and IOPS < 30% of provisioned for 30+ days
3. Downsize by one tier (e.g., `r5.2xlarge` → `r5.xlarge`) in staging first
4. Monitor for 2 weeks in staging, then apply to production during low-traffic window

### M1-4: ElastiCache right-sizing and reserved nodes
**Savings**: $10,000–$14,000/month (2–3%)
**Effort**: Medium
**Risk**: Low

- Enable CloudWatch metrics for eviction rate, cache hit ratio, memory utilization
- Clusters with > 40% free memory are over-provisioned
- Purchase 1-year Reserved Cache Nodes for stable clusters (35–40% savings)

**Month 1–2 Total Additional Savings**: **$36,000–$48,000/month** (9–11%)

---

## Month 2–3: Architectural Changes

### A1: Reduce inter-region data transfer (largest structural saving)
**Savings**: $25,000–$35,000/month (6–8%)
**Effort**: High — architectural change to data replication strategy
**Risk**: Medium — requires careful testing to avoid data consistency issues

**Problem**: $55,000/month in data transfer is primarily:
- Analytics data replicated from US to EU and AP regions ($20,000)
- Cross-region backups ($15,000)
- API call payloads replicated across regions ($20,000)

**Solutions**:
1. **Regional read replicas over full copies**: Instead of replicating all event data to
   AP-South-1, replicate only the data needed for that region's campaigns (60-70% reduction)

2. **S3 Cross-Region Replication filtering**: Only replicate objects with tag `replicate=true`
   ```hcl
   resource "aws_s3_bucket_replication_configuration" "selective" {
     rule {
       filter {
         tag {
           key   = "replicate"
           value = "true"
         }
       }
       destination { bucket = aws_s3_bucket.dest.arn }
     }
   }
   ```

3. **AWS Global Accelerator** for API traffic: Routes US-generated events to the nearest
   regional endpoint without double-charging for cross-region transfer
   (GA charges per GB but at a lower rate than cross-region transfer for most paths)

4. **S3 Transfer Acceleration** for large object uploads from customer SDKs

### A2: Migrate analytics queries to S3 + Athena from RDS
**Savings**: $12,000–$18,000/month (3–4%)
**Effort**: High — data pipeline refactoring
**Risk**: Low — analytics are read-only; no customer-facing impact

**Problem**: Analytics/reporting queries run against RDS, requiring large `r5` instances.
These queries are latency-tolerant (a report can take 10 seconds; it's not real-time).

**Solution**: Move analytics data to S3 Parquet via event streaming, query via Athena.
- Athena cost: ~$5/TB scanned (vs. RDS instance cost of $3,000+/month for query headroom)
- At 10TB analytics data: $50/query run vs. amortized $200/day RDS cost for query capacity

### A3: Graviton3 migration for EKS nodes
**Savings**: $10,000–$15,000/month (2–3%)
**Effort**: Medium — Karpenter NodePool update + container arm64 builds
**Risk**: Low — test in staging first; arm64 is widely supported

**Action**:
```yaml
# Karpenter NodePool: add arm64 instance types
requirements:
  - key: kubernetes.io/arch
    operator: In
    values: ["amd64", "arm64"]  # Allow both
  - key: node.kubernetes.io/instance-type
    operator: In
    values: ["m7g.xlarge", "m7g.2xlarge", "c7g.xlarge"]  # Graviton3 (20-40% cheaper)
```

Add `arm64` to multi-arch Docker builds in CI:
```yaml
# In .github/workflows/microservice-cicd.yml
- uses: docker/build-push-action@v5
  with:
    platforms: linux/amd64,linux/arm64  # Build for both architectures
```

**Month 2–3 Total Additional Savings**: **$47,000–$68,000/month** (11–16%)

---

## 90-Day Summary

| Initiative | Savings/Month | Effort | Risk |
|-----------|--------------|--------|------|
| **Week 1–2** | | | |
| QW-1: VPA right-sizing + resource optimization | $18,000–$25,000 | Low | Low |
| QW-2: Delete unused resources | $5,000–$8,000 | Low | Low |
| QW-3: S3 Intelligent-Tiering | $4,000–$6,000 | Low | None |
| QW-4: Spot for batch workloads | $15,000–$22,000 | Low | Low |
| **Month 1–2** | | | |
| M1-1: EC2 Compute Savings Plans | $28,000–$35,000 | Low | None |
| M1-2: RDS Reserved Instances | $18,000–$22,000 | Low | None |
| M1-3: RDS right-sizing | $8,000–$12,000 | Medium | Medium |
| M1-4: ElastiCache reserved + right-size | $10,000–$14,000 | Medium | Low |
| **Month 2–3** | | | |
| A1: Inter-region data transfer reduction | $25,000–$35,000 | High | Medium |
| A2: Analytics → S3 + Athena | $12,000–$18,000 | High | Low |
| A3: Graviton3 migration | $10,000–$15,000 | Medium | Low |
| **TOTAL** | **$153,000–$212,000** | | |

**Realistic achievable savings (accounting for partial completion)**: **$105,000–$140,000/month** (25–33%)

This meets the 25–30% target ($105,000–$126,000) with margin.

---

## Risk Mitigation

For Medium-risk initiatives:
1. Always test in staging for 1+ week before production
2. Stage rollouts: change one instance at a time with 24-hour monitoring between changes
3. Keep previous configuration in version control for instant rollback
4. Alert on RDS CPU > 80% and Cache eviction rate > 1% during right-sizing windows
