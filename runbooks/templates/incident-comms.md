# Incident Communication Templates

Use these templates for all incident communications. Fill in `{{ }}` placeholders.
Consistency reduces confusion and speeds up incident resolution.

---

## Template 1: Internal Slack — Incident Declaration

**Channel**: `#incidents`
**When**: Within 2 minutes of alert acknowledgment

```
🚨 INCIDENT DECLARED — {{ SEVERITY }}

**Service**: event-ingestion ({{ NAMESPACE }}/production)
**Alert**: KubePodCrashLooping
**Started**: {{ TIME_UTC }} UTC
**Incident Commander**: {{ YOUR_NAME }}
**Bridge**: [Zoom link] | Slack thread ↓

**Current Status**: Investigating
**Customer Impact**: {{ DESCRIBE_IMPACT | "Under investigation" }}

Tracking thread started. Updates every 10 minutes until resolved.
```

---

## Template 2: Internal Slack — Status Update

**When**: Every 10 minutes during active incident, or when status changes

```
📊 INCIDENT UPDATE — {{ TIME_UTC }} UTC  (T+{{ MINUTES_ELAPSED }}min)

**Status**: {{ Investigating | Identified | Mitigating | Monitoring | Resolved }}
**Current Error Rate**: {{ X }}%  (SLO burn rate: {{ X }}×)
**Pods healthy**: {{ X }}/{{ TOTAL }}
**Kafka consumer lag**: {{ X }} events

**What we know**:
{{ FINDINGS }}

**Actions taken**:
- {{ ACTION_1 }} ({{ TIME }})
- {{ ACTION_2 }} ({{ TIME }})

**Next steps**:
- {{ NEXT_ACTION }} — {{ OWNER }} — ETA {{ TIME }}

**ETA to resolution**: {{ TIME | "Unknown — escalating" }}
```

---

## Template 3: Internal Slack — Incident Resolution

**When**: Immediately after confirming resolution

```
✅ INCIDENT RESOLVED — {{ TIME_UTC }} UTC  (Duration: {{ DURATION }})

**Service**: event-ingestion
**Root Cause**: {{ ROOT_CAUSE_SUMMARY }}
**Fix Applied**: {{ FIX_DESCRIPTION }}

**Impact Summary**:
- Duration: {{ DURATION }}
- Events lost/delayed: {{ COUNT | "None" }}
- Customers affected: {{ COUNT | "0 — no data loss confirmed" }}
- SLO budget consumed: {{ X }}% of 28-day budget

**Follow-up Actions**:
- [ ] PIR document: due {{ DATE }} — Owner: {{ NAME }}
- [ ] Permanent fix: tracking issue {{ GITHUB_ISSUE_LINK }}
- [ ] Runbook update: {{ NEEDED | "No changes needed" }}

PIR will be shared in #engineering-all within 24 hours.
```

---

## Template 4: Customer-Facing — Status Page Update

**When**: 15 minutes after incident confirmation (earlier if customer-facing impact is confirmed)
**Platform**: status.clevertap.com

### Initial Status Page Post

```
Investigating — Event Processing Delays
Posted: {{ TIME_UTC }} UTC

We are investigating reports of delays in event processing. Our engineering
team has been notified and is actively investigating.

Services affected: Event Ingestion
Impact: {{ "Some events may be delayed" | "No customer data loss at this time" }}
Next update: {{ TIME_UTC + 30min }} UTC

We apologize for the inconvenience and will provide updates as our investigation progresses.
```

### Status Page Update

```
Identified — Event Processing Delays
Posted: {{ TIME_UTC }} UTC

We have identified the cause of the event processing delays:
{{ ROOT_CAUSE_CUSTOMER_FRIENDLY_DESCRIPTION }}

Our team is actively working on a fix.

Services affected: Event Ingestion
Current impact: {{ DESCRIBE_CURRENT_STATUS }}
Expected resolution: {{ ETA | "We are working to restore service as quickly as possible" }}
Next update: {{ TIME_UTC + 15min }} UTC
```

### Status Page Resolution

```
Resolved — Event Processing Delays
Posted: {{ TIME_UTC }} UTC

The event processing issue has been resolved as of {{ TIME_UTC }}.

Root cause: {{ ROOT_CAUSE_CUSTOMER_FRIENDLY }}
Resolution: {{ FIX_DESCRIPTION_CUSTOMER_FRIENDLY }}

Impact duration: {{ DURATION }}
{{ "All events have been processed and no data was lost." |
   "Events received between TIME_A and TIME_B may have been delayed.
    All such events have now been processed. No events were permanently lost." }}

We apologize for the disruption to your service. We will be publishing a
post-mortem within 5 business days.

If you have questions, please contact support@clevertap.com.
```

---

## Template 5: Stakeholder Email (Engineering Manager / VP)

**When**: P0/P1 incidents > 15 minutes with customer impact
**Recipients**: Engineering Manager, VP Engineering (BCC: on-call lead)

```
Subject: [INCIDENT] event-ingestion service degradation — {{ DATE }}

Hi {{ NAME }},

I wanted to flag an ongoing production incident affecting the event-ingestion service.

SUMMARY
Service: event-ingestion (event processing pipeline)
Start time: {{ TIME_UTC }} UTC
Duration so far: {{ DURATION }}
Severity: {{ P0 | P1 }}

CUSTOMER IMPACT
{{ DESCRIBE_CUSTOMER_IMPACT }}
Estimated affected events: {{ COUNT | "Under assessment" }}

CURRENT STATUS
{{ CURRENT_STATUS }}

WHAT WE'RE DOING
1. {{ ACTION_1 }}
2. {{ ACTION_2 }}
3. Expected resolution: {{ ETA }}

I'll send another update at {{ TIME }} or when the situation changes.

On-call Engineer: {{ YOUR_NAME }} ({{ PHONE }})
Incident Lead: {{ INCIDENT_LEAD }}
Slack Bridge: #incidents

{{ YOUR_NAME }}
Platform SRE Team
```

---

## Communication Principles

1. **Acknowledge first, diagnose second** — let stakeholders know someone is on it before you know the cause
2. **No blame in communications** — focus on symptoms and fixes, not who caused it
3. **Use UTC for all timestamps** — avoid timezone confusion across regions
4. **"Under investigation"** is an acceptable status — don't speculate on cause
5. **Be specific about impact** — "some users may experience delays" > "service degraded"
6. **Update on schedule** — if you said 10-minute updates, send them even if there's nothing new
7. **Never say customer data is lost unless confirmed** — this has legal implications
