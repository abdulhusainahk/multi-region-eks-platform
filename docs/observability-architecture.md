# Section 2a: Observability Architecture

CleverTap processes **40+ billion events/day across 4+ billion devices**. The observability
platform must handle extreme cardinality, support multi-tenant isolation, and enable
fast incident diagnosis. This document specifies the four-pillar observability stack.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│  Applications / EKS Nodes / AWS Services                             │
│                                                                      │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────────────┐ │
│  │ OTEL SDK │  │Prometheus│  │ Fluent   │  │ AWS CloudWatch /     │ │
│  │ (traces) │  │ scrape   │  │ Bit      │  │ VPC Flow Logs / EKS  │ │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └──────────┬───────────┘ │
└───────┼─────────────┼─────────────┼─────────────────────┼────────────┘
        │             │             │                     │
        ▼             ▼             ▼                     ▼
┌────────────────────────────────────────────────────────────────────┐
│  OpenTelemetry Collector (DaemonSet + Gateway deployment)          │
│  - Receives: OTLP (gRPC/HTTP), Prometheus, FluentForward           │
│  - Processes: batch, memory_limiter, k8s_attributes, resource      │
│  - Exports: to dedicated backends per signal type                  │
└──────────────┬───────────────────────┬──────────────────┬──────────┘
               │                       │                  │
        ┌──────▼──────┐         ┌──────▼──────┐   ┌──────▼──────┐
        │  Metrics    │         │   Traces    │   │    Logs     │
        │  Thanos     │         │   Grafana   │   │  Grafana    │
        │  (long-term)│         │   Tempo     │   │  Loki       │
        │  Prometheus │         │             │   │             │
        │  (short)    │         │             │   │             │
        └──────┬──────┘         └──────┬──────┘   └──────┬──────┘
               │                       │                  │
               └───────────────────────┴──────────────────┘
                                       │
                           ┌───────────▼──────────┐
                           │  Grafana (unified UI) │
                           │  - Dashboards         │
                           │  - Alerts → AlertMgr  │
                           │  - SLO burn-rate rules│
                           └───────────┬───────────┘
                                       │
                   ┌───────────────────┼───────────────────┐
                   ▼                   ▼                   ▼
           PagerDuty (P1/P2)    Slack (#alerts)      Jira (tickets)
```

---

## Pillar 1: Metrics

### Tooling: Prometheus + Thanos + Grafana

| Tool | Role | Justification |
|------|------|---------------|
| **Prometheus** (per-cluster) | Scrape + short-term storage (15d) | Industry standard; native Kubernetes service discovery; efficient label-based queries |
| **Thanos** (global) | Long-term storage, global query, deduplication | Seamlessly extends Prometheus; S3-backed; enables cross-cluster querying without federation complexity |
| **Grafana** | Visualization + SLO alerting | Best-in-class dashboards; native Prometheus + Thanos data sources; alerting rules co-located with dashboards |
| **kube-state-metrics** | Kubernetes object state metrics | Required for pod/deployment/node health metrics |
| **node-exporter** | Node-level OS/hardware metrics | CPU, memory, disk, network per node |
| **DCGM Exporter** (future) | GPU metrics if ML workloads added | — |

**Why not CloudWatch Metrics alone?**
CloudWatch cardinality limits (10 dimensions max per metric) and per-metric cost make it unsuitable for Kubernetes workloads at 40B events/day. Prometheus handles arbitrary label cardinality.

### Data Flow: Metrics
```
Apps (push OTLP) → OTEL Collector → Prometheus remote_write → Thanos Receiver
                                         ↑
Kubernetes (scrape) → Prometheus ────────┘
Node Exporter (scrape) → Prometheus

Thanos Receiver → Object Store (S3) → Thanos Store → Thanos Query → Grafana
                                                          ↑
Prometheus (short-term, 15d) → Thanos Sidecar ────────────┘
```

### Cardinality Management

Cardinality explosion is the #1 scaling problem at 40B events/day. At this scale, a single
high-cardinality label (e.g., `customer_id` with 4M tenants) can OOM a Prometheus instance.

**Controls:**

1. **OTEL Collector `transform` processor** — drop labels before they reach Prometheus:
   ```yaml
   # Strip customer_id from metrics; use aggregation instead
   transform/drop_high_cardinality:
     metric_statements:
       - context: datapoint
         statements:
           - delete_key(attributes, "customer_id")
           - delete_key(attributes, "campaign_id")
           - delete_key(attributes, "device_id")
   ```

2. **Prometheus `metric_relabel_configs`** — drop series at scrape time:
   ```yaml
   metric_relabel_configs:
     - source_labels: [__name__]
       regex: '(go_.*|process_.*|promhttp_.*)'
       action: drop  # Drop verbose Go runtime metrics
     - source_labels: [customer_id]
       action: labeldrop
   ```

3. **Recording rules** — pre-aggregate at ingest, reduce query-time cardinality:
   ```yaml
   # Instead of querying per-customer, pre-aggregate by region
   - record: job:clevertap_events_processed:rate5m
     expr: sum(rate(event_ingestion_processed_total[5m])) by (region, service)
   ```

4. **Cardinality quotas per job** — `max_samples_per_send` in remote_write, plus
   Thanos Ruler cardinality limits via `--tsdb.max-block-duration`.

5. **Vertical Pod Autoscaler** for Prometheus — auto-adjusts memory when cardinality spikes.

6. **Prometheus Cardinality Explorer** — weekly automated report identifying the top-20
   highest-cardinality metric series, sent to #observability-health Slack channel.

---

## Pillar 2: Logs

### Tooling: Fluent Bit + Grafana Loki

| Tool | Role | Justification |
|------|------|---------------|
| **Fluent Bit** | Log collector (DaemonSet) | Lightweight C-based agent; 5x less memory than Fluentd; built-in Kubernetes metadata enrichment |
| **Grafana Loki** | Log aggregation + storage | Label-based indexing (same model as Prometheus) prevents log indexing cardinality explosion; 10x cheaper than Elasticsearch at this scale; native LogQL correlates with Prometheus metrics |
| **S3** (via Loki chunks) | Long-term log storage | Same S3 bucket pattern as Thanos; lifecycle policies for cost control |

**Why not Elasticsearch?**
Elasticsearch indexes every word by default, making cardinality management at 40B events/day
prohibitively expensive in both storage and compute. Loki's label-based approach matches the
Prometheus mental model and keeps index size bounded.

**Why not CloudWatch Logs?**
CloudWatch Logs Insights queries are slow for large datasets and expensive at scale
(~$0.005/GB ingested). Loki is 80%+ cheaper for equivalent functionality.

### Structured Log Format

All services emit logs in JSON with these mandatory fields:
```json
{
  "timestamp": "2024-01-15T10:30:00.000Z",
  "level": "error",
  "service": "event-ingestion",
  "version": "v2.4.1",
  "trace_id": "7b4a9f2e-3c1d-4b8a-9e5f-2a7c6d1b8e4f",
  "span_id": "4d2a7b1c",
  "region": "us-east-1",
  "pod": "event-ingestion-7d9f8c4-xkp2n",
  "message": "Failed to publish to Kafka topic",
  "error": "connection timeout after 5000ms",
  "kafka_topic": "campaign-events",
  "retry_count": 3
}
```

**Loki Labels** (kept minimal to control cardinality):
- `namespace`, `pod`, `container`, `service`, `level`, `region`

**Do NOT** use tenant IDs, campaign IDs, or customer IDs as Loki labels.
Query by log content using `|= "customer_id=123"` instead.

### Data Flow: Logs
```
Pod stdout/stderr → Fluent Bit (DaemonSet) → OTEL Collector (fluentforward)
                                                    ↓
                                            Loki Distributor
                                                    ↓
                                         Loki Ingester (write-ahead log)
                                                    ↓
                                      S3 (chunks) + DynamoDB (index)
                                                    ↑
                                        Loki Querier → Grafana (LogQL)
```

---

## Pillar 3: Traces

### Tooling: OTEL SDK + Grafana Tempo

| Tool | Role | Justification |
|------|------|---------------|
| **OpenTelemetry SDK** | Instrumentation (language-native) | Vendor-neutral; single instrumentation for all backends; supports auto-instrumentation for Java/Go/Python |
| **OTEL Collector** | Trace pipeline (sampling, batching) | Tail-based sampling at gateway; keeps 100% of error traces, 1% of success traces |
| **Grafana Tempo** | Trace storage + query | S3-backed; zero-index means unlimited cardinality; native exemplar linking with Prometheus metrics; 10x cheaper than Jaeger at scale |

**Sampling Strategy** (critical at 40B events/day — cannot store all traces):
```
Head-based: 1% probabilistic sampling at SDK level (reduces data volume 100x)
Tail-based: OTEL Collector keeps:
  - 100% of traces with error spans
  - 100% of traces with latency > 500ms (p99 threshold)
  - 1% of all other traces
  - Always-on for traces tagged with debug=true
```

**Exemplars** link metrics to traces:
```yaml
# Prometheus scrape config
scrape_configs:
  - job_name: event-ingestion
    scrape_interval: 15s
    params:
      features: [exemplar-storage]
```

### Data Flow: Traces
```
App (OTEL SDK) → OTEL Collector (DaemonSet, OTLP receiver)
                        ↓ tail-based sampler
              OTEL Collector (Gateway, batch processor)
                        ↓ OTLP exporter
              Tempo Distributor → Tempo Ingester
                        ↓
              S3 (trace storage) ← Tempo Querier → Grafana (TraceQL)
```

---

## Pillar 4: Events

### Tooling: Kubernetes Events → CloudWatch → Grafana

| Signal | Source | Destination |
|--------|--------|-------------|
| Kubernetes events | kube-apiserver | Loki (via Fluent Bit) + CloudWatch |
| AWS CloudTrail | AWS API calls | CloudWatch → S3 → Athena |
| Deployment events | ArgoCD / GitHub Actions | Grafana annotations |
| Alertmanager events | Alert state changes | Loki + PagerDuty |

Deployment annotations in Grafana mark every deploy on every dashboard, enabling
instant correlation between a deployment and a metric/log anomaly.

---

## SLO-Based Alerting vs. Threshold-Based Alerting

### Why Threshold Alerts Fail at Scale

With >200 alerts/day, the team is experiencing "alert fatigue" — a well-documented phenomenon
where engineers begin ignoring alerts because most are noise. Threshold alerts have two failure modes:

1. **Too sensitive**: `CPU > 80%` fires every time there's a normal traffic spike
2. **Not sensitive enough**: A slow memory leak doesn't cross the threshold until 3 AM

### SLO-Based Alerting with Error Budget Burn Rate

An SLO defines an acceptable error rate over a **28-day rolling window**. Instead of alerting on
momentary threshold breaches, we alert when we're **consuming the error budget too fast**.

**Event Ingestion Service SLOs:**

| SLO | Target | Error Budget (28d) |
|-----|--------|--------------------|
| Availability (successful event processing) | 99.9% | 43.2 minutes downtime |
| Latency (p99 < 500ms) | 99.5% | 3.36 hours above threshold |
| Data durability (events published to Kafka) | 99.99% | 4.32 minutes lost |

**Error Budget Burn Rate Alerting:**

The [Google SRE Book's multi-window, multi-burn-rate approach](https://sre.google/workbook/alerting-on-slos/):

```
Burn Rate 1h = (error_rate_1h / (1 - SLO_target)) × (28d / 1h)

Alert if burn_rate_1h > 14.4  AND  burn_rate_5m > 14.4   → PAGE (2% budget in 1h)
Alert if burn_rate_6h > 6     AND  burn_rate_30m > 6      → TICKET (5% budget in 6h)
Alert if burn_rate_3d > 1                                  → INFORM (100% budget in 3d)
```

**Why this reduces alert noise by 80%+:**

| Scenario | Threshold Alert | SLO Burn Rate Alert |
|----------|-----------------|---------------------|
| 5-min traffic spike, 2% error rate | FIRES (noisy) | No alert (below burn rate) |
| 20-min partial outage, 15% error rate | FIRES once | FIRES (real incident) |
| 3-hour slow degradation, 1% error rate | Never fires | FIRES (budget burning) |
| Auto-resolving blip (current 60%) | FIRES and auto-resolves | **Never fires** |

The current 60% auto-resolving alert problem is directly caused by threshold alerts.
Multi-window burn rates require sustained budget consumption — transient blips don't accumulate.

### Implementation

SLO metrics flow:

```
Prometheus recording rules → SLO burn rate recording rules → Grafana alerting
                                   ↓
             observability/prometheus/rules/slo-event-ingestion.yaml
```

See [`observability/prometheus/rules/slo-event-ingestion.yaml`](../observability/prometheus/rules/slo-event-ingestion.yaml)
for the full Prometheus rule implementation.

---

## Unified Alerting Strategy

### Alert Routing (Alertmanager)

```yaml
route:
  receiver: slack-default
  group_by: [alertname, cluster, service]
  group_wait: 30s        # Collect related alerts before first notification
  group_interval: 5m     # How often to re-notify open alerts
  repeat_interval: 4h    # Don't re-page more than every 4 hours

  routes:
    # P1: Page immediately
    - match:
        severity: critical
        burn_rate_window: 1h
      receiver: pagerduty-high
      continue: false

    # P2: Ticket + Slack within 30m
    - match:
        severity: warning
        burn_rate_window: 6h
      receiver: pagerduty-low
      group_wait: 5m

    # Informational: Slack only
    - match:
        severity: info
      receiver: slack-info
      inhibit_rules:
        - target_match:
            severity: info
          source_match:
            severity: critical
          equal: [alertname, service]
```

### Alert Runbook Links

Every alert rule MUST include a `runbook_url` annotation pointing to the relevant runbook
in this repository:

```yaml
annotations:
  runbook_url: "https://github.com/clevertap/infra/blob/main/runbooks/pod-crash-looping.md"
  summary: "Event ingestion pod crash looping"
  description: "Pod {{ $labels.pod }} in namespace {{ $labels.namespace }} is crash looping"
```

---

## Cardinality Budget per Service

| Service | Max metric series | Max log volume/day | Max trace volume/day |
|---------|------------------|--------------------|-----------------------|
| event-ingestion | 50,000 | 500 GB | 2 GB (sampled) |
| campaign-delivery | 30,000 | 200 GB | 1 GB |
| analytics | 20,000 | 100 GB | 500 MB |
| infra (all) | 100,000 | 1 TB | 5 GB |

Teams that breach their cardinality budget receive an automated PR against their
service's relabeling config, proposing series to drop or aggregate.
