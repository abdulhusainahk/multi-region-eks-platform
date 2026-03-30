# Runbook: KubePodCrashLooping — Event Ingestion Service

| | |
|---|---|
| **Service** | `event-ingestion` |
| **Alert Name** | `KubePodCrashLooping` |
| **Severity** | Critical |
| **Audience** | On-call engineers (6+ months experience) |
| **Last Reviewed** | 2024-01-15 |
| **Owners** | `@platform-sre` |
| **Escalation** | See [Section 5: Escalation](#5-escalation-criteria) |

---

## What Is Happening

The `event-ingestion` service in the `production` namespace has one or more pods
continuously restarting (crash looping). This service:

- Receives inbound campaign events from customer SDKs (HTTP/gRPC)
- Validates, enriches, and deduplicates events
- Publishes processed events to the `campaign-events` Kafka topic
- Operates at **~500K events/second** at peak load

**Customer Impact**: Events that cannot be ingested are lost or delayed, directly
affecting campaign delivery and analytics accuracy. SLO burn rate will be elevated.

**Typical MTTR**: 10–25 minutes for experienced responders.

---

## 1. Initial Triage (Do This First — In Order)

> ⏱️ Target: complete within 5 minutes of alert firing

### Step 1.1 — Acknowledge the Alert

```bash
# In PagerDuty: click Acknowledge on the alert
# In Slack: react with 🔔 in #incidents to indicate you have picked it up
# Open the incident channel: /incident create "event-ingestion crash loop" sev:1
```

### Step 1.2 — Assess Scope and Blast Radius

```bash
# How many pods are affected?
kubectl get pods -n production -l app=event-ingestion \
  --sort-by='.status.containerStatuses[0].restartCount'

# Sample output — assess: is it 1 pod or all pods?
# NAME                              READY   STATUS             RESTARTS   AGE
# event-ingestion-7d9f8c4-xkp2n   0/1     CrashLoopBackOff   12         8m
# event-ingestion-7d9f8c4-ab4r2   1/1     Running            0          2h

# Check current SLO burn rate (open Grafana)
# Dashboard: https://grafana.clevertap.com/d/event-ingestion/event-ingestion-overview
# Look at: "Error Budget Burn Rate (multi-window)" panel
```

**Scope Decision:**
- **1 pod crashing** → likely OOMKill or node-specific issue; lower urgency
- **Multiple pods crashing** → likely bad deploy, config error, or dependency outage
- **All pods crashing** → P0 customer impact, immediate escalation

### Step 1.3 — Check Recent Events

```bash
# Get crash reason in one command
kubectl describe pod -n production \
  $(kubectl get pods -n production -l app=event-ingestion \
    -o jsonpath='{.items[?(@.status.containerStatuses[0].restartCount>0)].metadata.name}' \
    | awk '{print $1}') \
  | grep -A 10 "Last State:\|Events:"
```

**Interpret Exit Codes:**

| Exit Code | Meaning | Next Step |
|-----------|---------|-----------|
| `0` | Clean exit — app thinks it completed | Check logs for intentional shutdown |
| `1` | Unhandled exception / application error | Go to Step 1.4 (check logs) |
| `137` (SIGKILL) | OOMKilled | Go to Decision Tree: Scale-Out |
| `139` | Segfault | Likely binary corruption; roll back |
| `143` (SIGTERM) | Graceful shutdown | Check preStop hooks / liveness probes |

### Step 1.4 — Read the Crash Logs

```bash
# Current logs from crashing pod
kubectl logs -n production \
  $(kubectl get pods -n production -l app=event-ingestion \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}') \
  --previous --tail=100

# If pod is stuck in CrashLoopBackOff, get logs from the previous container run
POD=$(kubectl get pods -n production -l app=event-ingestion \
  -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n production "$POD" --previous --tail=200

# Stream live (catches intermittent crashes)
kubectl logs -n production -l app=event-ingestion -f --tail=50
```

**In Grafana Loki (better for correlating across pods):**
```logql
{namespace="production", service="event-ingestion"} |= "error" | level = "error"
  | json
  | line_format "{{.timestamp}} [{{.pod}}] {{.message}} {{.error}}"
```

### Step 1.5 — Check Recent Deployments

```bash
# Was there a recent deploy? (most crashes are caused by bad deploys)
kubectl rollout history deployment/event-ingestion -n production

# Check the exact time of last deploy vs. alert fire time
kubectl describe deployment event-ingestion -n production | grep "NewReplicaSet"

# Also check Grafana annotations — is there a blue deploy marker near the crash spike?
```

### Step 1.6 — Check Dependencies

The event-ingestion service has three critical dependencies. Check in order:

```bash
# 1. Kafka connectivity (most common cause of cascading restarts)
kubectl exec -n production \
  $(kubectl get pods -n production -l app=event-ingestion \
    -o jsonpath='{.items[0].metadata.name}') \
  -- nc -zv kafka-broker.kafka.svc.cluster.local 9092 2>&1
# Expected: "Connection to kafka-broker... succeeded"

# 2. Check Kafka consumer lag (is downstream healthy?)
# Grafana: "Kafka Consumer Lag" panel on event-ingestion dashboard
# Or:
kubectl exec -n kafka kafka-0 -- \
  kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe --group event-ingestion-consumer-group

# 3. Database/Redis connectivity
kubectl exec -n production \
  $(kubectl get pods -n production -l app=event-ingestion \
    -o jsonpath='{.items[0].metadata.name}') \
  -- sh -c 'redis-cli -h $REDIS_HOST ping; echo "exit: $?"'

# 4. Check if other services in production are also failing
kubectl get pods -n production | grep -v Running | grep -v Completed
```

### Step 1.7 — Check Resource Limits

```bash
# Is the pod OOMKilling? (exit 137)
kubectl describe pod -n production -l app=event-ingestion | grep -A 5 "OOMKilled\|Limits:"

# Current memory usage vs limits
kubectl top pods -n production -l app=event-ingestion --sort-by=memory
```

---

## 2. Decision Tree: Rollback vs. Hotfix vs. Scale-Out

```
Start
  │
  ├─ Was there a deployment in the last 2 hours?
  │    YES ──────────────────────────────────────────────────────►  [A] ROLLBACK
  │    NO
  │
  ├─ Is exit code 137 (OOMKilled)?
  │    YES ──────────────────────────────────────────────────────►  [B] SCALE-OUT
  │    NO
  │
  ├─ Is a critical dependency DOWN? (Kafka, Redis, DB)
  │    YES ──────────────────────────────────────────────────────►  [C] DEPENDENCY INCIDENT
  │    NO
  │
  ├─ Is there a configuration change (ConfigMap/Secret) in last 2h?
  │    YES ──────────────────────────────────────────────────────►  [A] ROLLBACK CONFIG
  │    NO
  │
  ├─ Is the error a known regression / temporary bug?
  │    YES ──────────────────────────────────────────────────────►  [D] HOTFIX
  │    NO
  │
  └─ Unknown cause — escalate and enable debug logging            ►  [E] ESCALATE
```

---

### [A] Rollback

> **Use when**: Bad deploy is confirmed as the cause.
> **Time to execute**: 3–5 minutes.

```bash
# 1. Check rollout history to identify target revision
kubectl rollout history deployment/event-ingestion -n production
# REVISION  CHANGE-CAUSE
# 5         v2.4.1 — add retry logic
# 4         v2.4.0 — feature X
# 3         v2.3.9 — hotfix for Y

# 2. Roll back to previous stable revision
kubectl rollout undo deployment/event-ingestion -n production
# OR to a specific revision:
kubectl rollout undo deployment/event-ingestion -n production --to-revision=4

# 3. Monitor rollout
kubectl rollout status deployment/event-ingestion -n production --timeout=5m

# 4. Confirm pods are stable
kubectl get pods -n production -l app=event-ingestion -w
# Watch for 0 restarts for 2+ minutes

# 5. Confirm SLO metrics recovering
# Grafana: check error rate is dropping toward baseline
# Wait for burn rate to return below the warning threshold (6x)
```

**After rollback:**
- File a P2 GitHub Issue on the service repository with tag `rollback-required`
- The failed version must not be re-deployed until the root cause is fixed and tested

---

### [B] Scale-Out (OOMKilled)

> **Use when**: Pods are exit 137, memory limits are being hit, traffic is elevated.
> **Time to execute**: 5–10 minutes.

```bash
# 1. Confirm memory pressure
kubectl describe nodes | grep -A 5 "MemoryPressure\|Allocated resources"
kubectl top pods -n production -l app=event-ingestion --sort-by=memory

# 2. Temporarily increase memory limits (short-term mitigation)
# WARNING: Do NOT increase indefinitely — this masks a memory leak
kubectl patch deployment event-ingestion -n production \
  --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"4Gi"}]'

# 3. Scale out replicas to distribute load
kubectl scale deployment event-ingestion -n production --replicas=12
# (from default 8)

# 4. Monitor recovery
kubectl rollout status deployment/event-ingestion -n production

# 5. Check if this is a traffic spike or a memory leak
# Grafana: compare throughput (events/sec) vs memory usage trend
# If throughput is normal but memory is growing → memory LEAK → escalate to dev team
# If throughput is 10x+ normal → traffic spike → autoscaler catching up

# 6. Check HPA is configured
kubectl get hpa -n production event-ingestion
kubectl describe hpa -n production event-ingestion
```

**After scale-out:**
- Create a P2 incident to investigate root cause (memory leak vs traffic spike)
- Update VPA/HPA settings if limits are genuinely too low

---

### [C] Dependency Incident

> **Use when**: Kafka / Redis / database is down or returning errors.

```bash
# Kafka: check broker health
kubectl get pods -n kafka
kubectl logs -n kafka kafka-0 --tail=50

# If Kafka is DOWN:
# 1. Check MSK console / CloudWatch: https://console.aws.amazon.com/msk
# 2. Check if consumer lag spike preceded the crash
# 3. Kafka restart should be handled by the Kafka on-call (escalate)

# Temporary mitigation: enable event-ingestion's dead letter queue mode
# (if implemented) or reduce replicas to 0 to prevent crash loop storm
kubectl scale deployment event-ingestion -n production --replicas=0

# IMPORTANT: Stopping event-ingestion means events ARE BEING LOST
# Only do this if the crash loop is causing more damage than a clean stop
# Document this decision in the incident channel immediately
```

---

### [D] Hotfix

> **Use when**: Root cause is a known bug with a simple code fix.
> **Time to execute**: 30–60 minutes (includes build + review + deploy).

For on-call engineers with < 1 year experience:
1. **Do NOT attempt hotfixes alone** — involve the service owner
2. Prefer rollback while the hotfix is being prepared
3. The hotfix must go through CI/CD staging before production

```bash
# While hotfix is being prepared, stabilize by rolling back first
kubectl rollout undo deployment/event-ingestion -n production

# When hotfix image is ready:
kubectl set image deployment/event-ingestion \
  -n production \
  event-ingestion=<ECR_IMAGE>:<hotfix-tag>

# Monitor
kubectl rollout status deployment/event-ingestion -n production
```

---

### [E] Escalation (Unknown Cause)

When none of the above explains the crash:

```bash
# Enable verbose logging temporarily
kubectl set env deployment/event-ingestion -n production LOG_LEVEL=debug

# Capture a heap dump or thread dump if OOM suspected (Java service)
# Replace with appropriate command for your runtime
kubectl exec -n production \
  $(kubectl get pods -n production -l app=event-ingestion \
    -o jsonpath='{.items[0].metadata.name}') \
  -- jmap -heap 1 > /tmp/heapdump-$(date +%Y%m%d-%H%M%S).txt

# Get a flame graph / CPU profile (if pprof enabled — Go service)
kubectl port-forward -n production svc/event-ingestion 6060:6060 &
curl http://localhost:6060/debug/pprof/heap > /tmp/pprof-heap.out
go tool pprof -pdf /tmp/pprof-heap.out > /tmp/flamegraph.pdf

# Escalate to service owner (see Section 5)
```

---

## 3. Immediate Mitigation Options

| Situation | Action | Command |
|-----------|--------|---------|
| Bad deploy | Rollback | `kubectl rollout undo deployment/event-ingestion -n production` |
| OOMKilled | Increase memory limits + scale | See [B] above |
| All pods crashing | Stop crash loop, accept partial outage | `kubectl scale deployment event-ingestion -n production --replicas=0` |
| High error rate but some pods running | Remove crashing pods | `kubectl delete pod -n production <crashing-pod-name>` |
| Kafka lag building up | Scale up Kafka consumers | `kubectl scale deployment campaign-processor -n production --replicas=20` |

---

## 4. Useful Queries

### Grafana (Loki — Logs)
```logql
# All errors in last 15 minutes
{namespace="production", service="event-ingestion"} | json | level="error"

# Crash reason correlation
{namespace="production"} |= "OOMKilled" | json

# Kafka connection errors
{namespace="production", service="event-ingestion"} |= "kafka" |= "connection"
```

### Grafana (Prometheus — Metrics)
```promql
# SLO burn rate (is it a blip or sustained?)
job:event_ingestion_errors:ratio_rate1h / 0.001

# Which pods are restarting?
increase(kube_pod_container_status_restarts_total{
  namespace="production", service="event-ingestion"
}[15m]) > 0

# Memory usage vs limit
container_memory_working_set_bytes{namespace="production", container="event-ingestion"}
/ container_spec_memory_limit_bytes{namespace="production", container="event-ingestion"}

# Kafka consumer lag
kafka:consumer_group_lag:sum{topic="campaign-events"}
```

### CloudWatch Logs Insights (for AWS-level issues)
```sql
-- EKS node system events
fields @timestamp, @message
| filter @logStream = "system"
| filter @message like /OOM|killed|evicted/
| sort @timestamp desc
| limit 50
```

---

## 5. Escalation Criteria

### Escalate Immediately (< 2 minutes) If:

- All pods are crash looping (complete service outage)
- Error budget is burning at > 50× rate
- Data loss is confirmed (Kafka publish failures > 0.01%)
- You cannot determine the cause after following Steps 1.1–1.7
- The incident has been ongoing for > 15 minutes with no improvement

### Escalation Path

| Who | When | How |
|-----|------|-----|
| **Event Ingestion Service Owner** | Any time | PagerDuty: `@service-owner-event-ingestion` |
| **Staff SRE / On-call Lead** | Outage > 10 min or unknown cause | PagerDuty escalation policy |
| **Engineering Manager** | Customer-visible impact > 15 min | Slack DM + phone |
| **CTO / VP Engineering** | P0 with no ETA to resolution > 30 min | Phone only |

### Communication Templates

See [`runbooks/templates/incident-comms.md`](templates/incident-comms.md) for:
- Internal Slack incident update template
- Customer-facing status page message template
- Stakeholder email template

---

## 6. Resolution Verification

Before closing the incident, confirm ALL of the following:

```bash
# 1. No pods restarting
kubectl get pods -n production -l app=event-ingestion
# All should show 0 restarts and STATUS=Running

# 2. SLO burn rate is below threshold
# Grafana: "Error Budget Burn Rate" panel — both 1h and 6h should be < 6

# 3. Kafka lag is draining (not growing)
# Grafana: "Kafka Consumer Lag" panel — should be decreasing

# 4. Throughput is back to baseline
# Grafana: "Event Processing Throughput" panel — should match pre-incident rate

# 5. Error rate is at baseline
kubectl top pods -n production -l app=event-ingestion
```

Disable debug logging if it was enabled:
```bash
kubectl set env deployment/event-ingestion -n production LOG_LEVEL=info
```

---

## 7. Post-Incident Tasks

Within **24 hours** of incident resolution:

1. Complete the PIR document: [`runbooks/templates/pir-template.md`](templates/pir-template.md)
2. Create a follow-up ticket for any contributing factors not yet fixed
3. Update this runbook if any steps were unclear or missing
4. Review if this incident should trigger an SLO review (if budget is < 20% remaining)

---

## Related Runbooks

- [`runbooks/kafka-consumer-lag.md`](kafka-consumer-lag.md) — Kafka consumer lag runbook
- [`runbooks/oom-kill.md`](oom-kill.md) — OOMKilled investigation
- [`docs/observability-architecture.md`](../docs/observability-architecture.md) — observability stack overview
- [`docs/alert-noise-reduction.md`](../docs/alert-noise-reduction.md) — SLO alerting design
