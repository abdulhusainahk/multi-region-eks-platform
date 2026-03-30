# Section 2c: Reducing Alert Noise — Systematic Approach

## The Problem

**60% of alerts auto-resolve within 5 minutes without human action.** This is alert fatigue
at its most damaging: engineers are being trained to ignore alerts. Research shows that
organizations with >30% "auto-resolve" alerts experience:

- 3-5× longer MTTR when real incidents occur (because engineers dismiss the page)
- 40% higher on-call engineer attrition vs. low-noise teams
- A normalization of deviance where "alert = noise" becomes the default assumption

This document describes a systematic approach to auditing, classifying, and remediating
the alert backlog, and defines ongoing health metrics for the alerting system.

---

## Phase 1: Audit — Understand What You Have

Before changing anything, build a data-driven picture of the alert landscape.

### 1.1 Export Alert History

```bash
# Pull 90 days of alert history from Alertmanager API
curl -s 'http://alertmanager.monitoring.svc.cluster.local:9093/api/v1/alerts' \
  | jq '.data[] | {
      alertname: .labels.alertname,
      service: .labels.service,
      severity: .labels.severity,
      start: .startsAt,
      end: .endsAt,
      duration_minutes: (((.endsAt | fromdate) - (.startsAt | fromdate)) / 60 | floor)
    }' > /tmp/alert-audit.json

# Or query Prometheus TSDB directly for alertmanager_alerts_received_total
```

### 1.2 Build the Alert Taxonomy

Classify every distinct alert rule (not instance) into a 2×2 matrix:

```
                    ┌──────────────────────────────────────────────┐
                    │                 ACTIONABLE?                   │
                    │         No               Yes                  │
  ┌─────────────────┼──────────────────────────────────────────────┤
  │           Noisy │  ❌ DELETE                │  🔧 FIX THRESHOLD │
  │  FREQUENCY      │  (auto-resolves, no       │  (fire duration   │
  │                 │  action, not correlated   │  is too short)    │
  │                 │  to real issues)          │                   │
  ├─────────────────┼──────────────────────────────────────────────┤
  │          Quiet  │  🔇 SILENCE/ARCHIVE       │  ✅ KEEP          │
  │                 │  (rare false positives)   │  (working as     │
  │                 │                           │  intended)       │
  └─────────────────┴──────────────────────────────────────────────┘
```

### 1.3 Data Collection Queries (Prometheus)

```promql
# Alert firing frequency over 90 days
count by (alertname) (
  count_over_time(ALERTS{alertstate="firing"}[90d])
)

# Average duration per alert (minutes)
avg by (alertname) (
  (ALERTS_FOR_STATE - ALERTS{alertstate="firing", for!=""}) / 60
)

# Auto-resolve rate: proportion of firings with duration < 5 minutes
sum by (alertname) (
  rate(alertmanager_notifications_total{status="resolved"}[90d])
  and on(alertname)
  (ALERTS_FOR_STATE < 300)  # < 5 minutes
)
/ sum by (alertname) (
  rate(alertmanager_notifications_total{status="resolved"}[90d])
)
```

### 1.4 Alert Audit Spreadsheet Fields

For each distinct alert rule, capture:

| Field | How to Get It |
|-------|---------------|
| `alert_name` | Prometheus rule file |
| `total_firings_90d` | Prometheus query above |
| `median_duration_min` | Prometheus query above |
| `auto_resolve_rate` | (firings < 5min) / total_firings |
| `human_action_required_rate` | From PagerDuty: how often was the alert actioned? |
| `false_positive_rate` | From PagerDuty: "Acknowledged then resolved without action" |
| `correlated_with_incident` | Cross-reference with incident log |
| `has_runbook` | Check annotations.runbook_url exists |
| `last_updated` | Git blame on the rule file |

---

## Phase 2: Classify — The Alert Triage Decision Tree

Apply this decision tree to every alert with `auto_resolve_rate > 0.3`:

```
Is the alert correlated with a real incident at least once in 90 days?
├── NO → Does it have any diagnostic value (linked to user impact metric)?
│         ├── NO  → CANDIDATE FOR DELETION
│         └── YES → CANDIDATE FOR SEVERITY DOWNGRADE (info only, no page)
└── YES → Is the duration consistently < 5 minutes when it fires?
           ├── YES → THRESHOLD IS TOO SENSITIVE — increase `for:` duration
           │         OR convert to SLO burn rate alert
           └── NO  → Is there a runbook?
                      ├── NO  → ADD RUNBOOK (keep alert, fix documentation)
                      └── YES → KEEP (alert is working correctly)
```

---

## Phase 3: Remediation — 6 Categories of Action

### Category 1: DELETE — Zero-value alerts

**Criteria**: `auto_resolve_rate > 0.8` AND `correlated_with_incident = 0`

These alerts have never contributed to incident detection or diagnosis. Deleting them
immediately reduces alert volume with zero risk.

```bash
# Before deleting: search for any incident where this alert was the first signal
grep -r "KubeNodeNotReady" /var/log/incidents/ 2>/dev/null || echo "Never referenced"
```

**Common candidates at CleverTap:**
- `KubeNodeNotReady` with `for: 1m` (node flaps during rolling upgrades)
- `PodPendingTooLong` with threshold lower than normal scheduler latency
- Rate limit warnings that fire during every traffic spike but require no action
- Synthetic heartbeat alerts that resolve before anyone reads them

### Category 2: LENGTHEN `for:` DURATION — Transient alerts

**Criteria**: `auto_resolve_rate > 0.5` AND `correlated_with_incident > 0`

The alert IS meaningful when sustained, but the `for:` window is too short.
The fix is to increase the minimum sustained duration before firing.

```yaml
# BEFORE (noisy):
- alert: KubePodCrashLooping
  expr: increase(kube_pod_container_status_restarts_total[5m]) > 1
  for: 1m   # fires on 2nd restart in 5 min — too sensitive

# AFTER (actionable):
- alert: KubePodCrashLooping
  expr: increase(kube_pod_container_status_restarts_total[15m]) > 3
  for: 5m   # requires 4+ restarts in 15 min AND sustained for 5 min
```

**Rule of thumb**: `for:` should be >= the typical auto-resolve duration.
If alerts auto-resolve in 3 minutes, set `for: 5m`.

### Category 3: CONVERT TO SLO BURN RATE — Threshold alerts

**Criteria**: Alert is correlated with incidents but has high auto-resolve rate
due to transient spikes that don't represent real user impact.

This is the highest-leverage change. Replace:
```yaml
# BEFORE: fires every traffic spike
- alert: HighErrorRate
  expr: rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m]) > 0.01
  for: 2m
```

With:
```yaml
# AFTER: only fires when error budget is genuinely at risk
- alert: EventIngestionAvailabilitySLOCritical
  expr: |
    job:event_ingestion_errors:ratio_rate1h > (14.4 * 0.001)
    and
    job:event_ingestion_errors:ratio_rate5m > (14.4 * 0.001)
  for: 2m
```

See `observability/prometheus/rules/slo-event-ingestion.yaml` for the full implementation.

### Category 4: INHIBIT — Redundant alerts during known incidents

**Criteria**: Alert always fires alongside a higher-severity alert. Separate notification adds no value.

```yaml
# Alertmanager inhibition rules
inhibit_rules:
  # Don't page for pod-level alerts when the SLO burn rate alert is already firing
  - source_matchers:
      - alertname = "EventIngestionAvailabilitySLOCritical"
    target_matchers:
      - alertname =~ "KubePodCrashLooping|KubePodNotReady|KubeDeploymentReplicasMismatch"
    equal: [service, namespace]

  # Don't send CPU/memory warnings when a node is already NotReady
  - source_matchers:
      - alertname = "KubeNodeNotReady"
    target_matchers:
      - alertname =~ "NodeHighCPU|NodeHighMemory"
    equal: [node]
```

### Category 5: DOWNGRADE SEVERITY — Informational signals

**Criteria**: Alert is useful for trending/post-incident but does not require human action.

Change `severity: warning` → `severity: info` and route only to Slack (not PagerDuty).

```yaml
# Alertmanager routing: info alerts go to Slack only
routes:
  - match:
      severity: info
    receiver: slack-info-channel
    repeat_interval: 24h
    group_wait: 10m
```

### Category 6: ADD RUNBOOKS — Actionable but undocumented

**Criteria**: Alert fires, humans do act on it, but there's no `runbook_url` annotation.

```bash
# Find alerts without runbook_url annotations
grep -r "alert:" observability/prometheus/rules/ \
  | while read -r file; do
    basename=$(dirname "$file")
    if ! grep -q "runbook_url" "$(echo "$file" | cut -d: -f1)"; then
      echo "MISSING RUNBOOK: $file"
    fi
  done
```

---

## Phase 4: Implementation — 30-Day Remediation Sprint

### Week 1: Quick Wins (no risk)
- [ ] Delete all Category 1 alerts (zero-value)
- [ ] Downgrade all Category 5 alerts to `info`
- [ ] Add inhibition rules for Category 4 redundant alerts
- [ ] Expected impact: **-40% alert volume**

### Week 2: Threshold Tuning
- [ ] Lengthen `for:` on all Category 2 alerts
- [ ] Re-validate against last 90 days: do the new thresholds still catch real incidents?
- [ ] Expected impact: **-20% additional alert volume**

### Week 3: SLO Conversion
- [ ] Convert top-5 highest-volume Category 3 alerts to SLO burn rate
- [ ] Run SLO alerts in parallel with old threshold alerts for 1 week (shadow mode)
- [ ] Compare: does the SLO alert catch everything the threshold alert catches?
- [ ] Expected impact: **-15% additional alert volume** + dramatically lower noise

### Week 4: Documentation + Measurement Baseline
- [ ] Add `runbook_url` to all remaining Category 6 alerts
- [ ] Establish Week 1 metrics baseline (see Section 5)
- [ ] Schedule monthly alert review meeting

---

## Phase 5: Ongoing Health Metrics for the Alerting System

These metrics should be tracked on a dedicated **"Alerting Health" Grafana dashboard**
and reviewed monthly by the on-call lead.

### Metric 1: Alert-to-Incident Ratio

```
Definition: (Alerts that led to a declared incident) / (Total alerts)
Target:      > 30% (at least 1 in 3 alerts should represent a real incident)
Current:     ~5% (we page 200/day, have ~10 incidents/day)
```

### Metric 2: Auto-Resolve Rate

```
Definition: (Alerts resolved within 5 minutes without human action) / (Total alerts)
Target:      < 10%
Current:     60% (our primary problem to solve)
```

### Metric 3: Mean Time to Acknowledge (MTTA)

```
Definition: Average time from alert fire to engineer acknowledgment
Target:      < 3 minutes for P1, < 15 minutes for P2
Rationale:   If MTTA is high, engineers are ignoring/fatigued by alerts
```

### Metric 4: Mean Time to Resolve (MTTR)

```
Definition: Average time from alert fire to incident resolution
Target:      P1 < 30 min, P2 < 2 hours, P3 < 1 business day
```

### Metric 5: Alert Coverage Rate

```
Definition: (Incidents detected by alerts) / (Total incidents)
Target:      > 90%
Rationale:   Measures whether our alerting misses real incidents
Measured by: Checking PIR documents: was there an alert before detection?
```

### Metric 6: Runbook Coverage

```
Definition: (Alerts with runbook_url) / (Total alert rules)
Target:      100%
Current:     ~30% (estimated)
```

### Metric 7: Alert Staleness

```
Definition: (Alert rules not updated in > 6 months) / (Total alert rules)
Target:      < 10%
Rationale:   Stale alerts accumulate as thresholds drift from reality
```

### Prometheus Queries for Alert Health Dashboard

```promql
# Alert auto-resolve rate over 30d
(
  sum(increase(alertmanager_notifications_total{status="resolved"}[30d]))
  - sum(increase(alertmanager_notifications_total{
      status="resolved", duration!~"[3-9][0-9][0-9]|[0-9]{4,}"
    }[30d]))
)
/ sum(increase(alertmanager_notifications_total{status="resolved"}[30d]))

# MTTA: time from firing to first acknowledgment (from PagerDuty webhook data)
histogram_quantile(0.50, rate(pagerduty_ack_time_seconds_bucket[30d]))

# Alerts per day by severity
sum by (severity) (
  increase(alertmanager_notifications_total[1d])
)
```

---

## Summary: Expected Outcomes After 30-Day Sprint

| Metric | Before | Target After 30d |
|--------|--------|-----------------|
| Alerts/day | 200 | < 40 (−80%) |
| Auto-resolve rate | 60% | < 10% |
| Alert-to-incident ratio | 5% | > 30% |
| MTTA (P1) | ~8 min (fatigue effect) | < 3 min |
| Runbook coverage | ~30% | 100% |
| On-call engineer satisfaction | Low | Measured via quarterly survey |

**The fundamental principle**: Every alert should represent a situation where a human
engineer is the best available solution. If a computer can resolve it automatically,
it shouldn't be an alert — it should be an automated remediation.
