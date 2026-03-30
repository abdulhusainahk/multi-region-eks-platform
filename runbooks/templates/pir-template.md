# Post-Incident Review (PIR) Template

> **Due**: Within 24 hours of incident resolution
> **Owner**: On-call engineer who resolved the incident (may delegate to service owner)
> **Review Meeting**: Scheduled within 5 business days for P0/P1 incidents
> **Distribution**: #engineering-all, affected team leads, Engineering Manager

---

## Incident Summary

| Field | Value |
|-------|-------|
| **Incident ID** | INC-{{ YYYY-MM-DD-NNN }} |
| **Title** | {{ SHORT_DESCRIPTION }} |
| **Severity** | {{ P0 \| P1 \| P2 }} |
| **Service(s)** | {{ event-ingestion, ... }} |
| **Start Time** | {{ UTC datetime }} |
| **Detection Time** | {{ UTC datetime }} |
| **Resolution Time** | {{ UTC datetime }} |
| **Total Duration** | {{ HH:MM }} |
| **Detection-to-Acknowledge** | {{ MM:SS }} |
| **Acknowledge-to-Mitigate** | {{ HH:MM }} |
| **Incident Commander** | {{ Name }} |
| **On-Call Engineer** | {{ Name }} |
| **Reviewers** | {{ Names }} |

---

## Impact Assessment

### Quantitative Impact

| Metric | Value |
|--------|-------|
| Events delayed | {{ COUNT \| "0" }} |
| Events permanently lost | {{ COUNT \| "0" }} |
| Customer-visible errors | {{ COUNT \| "0" }} |
| Affected customers | {{ COUNT \| "0" }} |
| SLO error budget consumed | {{ X }}% of 28-day budget |
| Revenue impact | {{ $X \| "None identified" }} |

### Customer Experience

<!-- Describe what customers experienced, if anything -->

> Example: "Customers who triggered campaigns between 14:32 and 14:58 UTC may have
> seen delayed event processing. All events were processed within 12 minutes of
> resolution. No events were permanently lost."

---

## Timeline

> List events in chronological order. Be specific — include exact timestamps.
> This section is the most important part of the PIR.

| Time (UTC) | Event |
|------------|-------|
| 14:30 | Deployment of `event-ingestion:v2.4.1` to production |
| 14:32 | `KubePodCrashLooping` alert fires in PagerDuty |
| 14:33 | Alert acknowledged by {{ ENGINEER }} |
| 14:34 | Incident declared in #incidents |
| 14:35 | Identified 3/8 pods in CrashLoopBackOff, exit code 137 (OOMKilled) |
| 14:38 | Memory limit increased from 2Gi to 4Gi, replicas scaled to 12 |
| 14:42 | All pods healthy, SLO burn rate returning to baseline |
| 14:50 | Confirmed full recovery, Kafka consumer lag draining |
| 14:52 | Incident resolved |
| 15:10 | Debug logging disabled, memory investigation scheduled |

---

## Root Cause Analysis

### What happened

<!-- Describe the technical root cause in plain English. Avoid jargon. -->

### Why it happened

<!-- The 5 Whys — trace back to the systemic root cause, not just the proximate cause -->

**Why #1**: {{ pods crashed }}
**Why #2**: {{ pods ran out of memory }}
**Why #3**: {{ new version allocated 3x more memory for event batching cache }}
**Why #4**: {{ memory requirements were not profiled before deploy }}
**Why #5**: {{ load testing environment doesn't reflect production traffic volume }}

**Root Cause**: {{ systemic issue }}

### Contributing Factors

<!-- What made this incident worse, harder to detect, or harder to fix? -->

- [ ] No staging load test at production traffic scale
- [ ] Memory limits had not been reviewed since traffic grew 3x in Q3
- [ ] Alerting only fired after 5 minutes (could have been 2 minutes)
- [ ] Deploy was not paired with a VPA recommendation review

---

## Detection Analysis

| Question | Answer |
|----------|--------|
| How was it detected? | PagerDuty: KubePodCrashLooping alert |
| Was this the right detection method? | Yes — SLO burn rate also elevated |
| Was detection delayed? | No — fired within 3 minutes of first crash |
| Could we detect this earlier? | Yes — see Action Items |

### Alert Quality Assessment

- Did the alert fire at the right time? **{{ Yes | No }}**
- Was the alert actionable (did you know what to do)? **{{ Yes | No }}**
- Was the runbook link correct and helpful? **{{ Yes | No }}**
- Did the alert auto-resolve without human action? **{{ Yes | No }}**

---

## Response Analysis

| Question | Answer |
|----------|--------|
| Was the runbook followed? | {{ Yes \| Mostly \| No (explain) }} |
| Was the runbook accurate and complete? | {{ Yes \| Missing Step X }} |
| Was communication timely? | {{ Yes \| Delayed because... }} |
| Was escalation appropriate? | {{ Yes \| Should have escalated sooner/later }} |
| Were the right people involved? | {{ Yes \| Missing: service owner }} |

---

## Action Items

> Each action item must have an owner and a due date.
> Add to GitHub Issues with label `incident-followup` and link here.

| Priority | Action | Owner | Due Date | GitHub Issue |
|----------|--------|-------|----------|--------------|
| P1 | Add production-scale load test to CI pipeline | {{ Service Team }} | {{ +2 weeks }} | #{{ N }} |
| P1 | Configure VPA for event-ingestion, review all resource limits | {{ SRE Team }} | {{ +1 week }} | #{{ N }} |
| P2 | Add pre-deploy memory profiling check to GitHub Actions | {{ Platform }} | {{ +3 weeks }} | #{{ N }} |
| P2 | Reduce KubePodCrashLooping alert `for` from 5m to 2m | {{ SRE Team }} | {{ +1 week }} | #{{ N }} |
| P3 | Update this runbook with OOMKill specific steps | {{ On-call Lead }} | {{ +1 week }} | — |

---

## What Went Well

> Focus on things that limited blast radius or enabled fast recovery.
> These should be amplified, not just mentioned.

- Alert fired within 3 minutes of first crash
- Rollback completed in 90 seconds
- All engineers followed the runbook procedure correctly
- Communication cadence was consistent throughout

---

## What Went Poorly

> Be honest and specific. This section is blameless — it's about systems, not people.

- Load testing did not simulate production memory load
- VPA was not monitoring the service — resource limits were stale
- Initial deploy did not include a memory usage comparison with v2.4.0

---

## Lessons Learned

> What would you tell the next on-call engineer to help them handle a similar incident faster?

1. Always check memory usage trends 5–10 minutes before declaring stability after a deploy
2. OOMKill in production almost always means resource limits need review, not just increase
3. When a deploy causes OOMKill, scale horizontally AND increase limits — horizontal scaling alone doesn't help if each pod hits the limit

---

## SLO Impact

| SLO | Budget Consumed This Incident | Total Consumed This Month | Budget Remaining |
|-----|-------------------------------|---------------------------|------------------|
| Availability (99.9%) | 0.3% (8 min) | 2.1% (54 min) | 97.9% |
| Latency p99 (99.5%) | 0.8% | 3.4% | 96.6% |

If total monthly budget consumed > 50%, trigger an SLO review meeting.

---

## Sign-off

This PIR has been reviewed and is accurate to the best of our knowledge.

| Role | Name | Date |
|------|------|------|
| Author | | |
| Service Owner | | |
| On-call Lead | | |
| Engineering Manager | | |
