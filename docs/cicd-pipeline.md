# Section 3a: CI/CD Pipeline Design

## Overview

CleverTap's microservice deployment pipeline is built on GitHub Actions with Helm and
Argo Rollouts, designed to support 10+ deploys/day for high-velocity teams while
giving risk-averse teams the confidence to deploy more frequently.

**Key design principles:**
1. **Same artifact, all stages** — Docker image tagged with commit SHA is built once and
   promoted unchanged through staging → production. No rebuilds at any stage.
2. **Fail fast** — SAST and test failures block at PR time, not at deploy time.
3. **Zero-secrets-in-YAML** — no credentials in any workflow file, Helm values, or config.
4. **Automated safety nets** — canary analysis rolls back automatically; humans only
   need to act for escalations.

See the implementation in:
- `.github/workflows/microservice-cicd.yml` — full GitHub Actions pipeline
- `cicd/helm/microservice/` — Helm chart with Argo Rollouts support
- `cicd/smoke-tests/smoke-test.sh` — staging smoke test script

---

## Stage 1: PR Pipeline

Every pull request runs four parallel jobs. All must pass before merge is permitted.

```
                    ┌──────────┐
                    │  PR open │
                    └────┬─────┘
                         │  (parallel)
          ┌──────────────┼──────────────┬──────────────┐
          ▼              ▼              ▼              ▼
       lint          unit-tests      build-push     (waits for build-push)
    (10 min)          (15 min)        (20 min)
                                          │
                                    sast-scan
                                    (15 min)
          └──────────────┴──────────────┴──────────────┘
                                   │
                          All pass → merge allowed
```

### PR Job: Lint
- Language-appropriate linter (golangci-lint / ESLint)
- Helm chart lint with `--strict`
- Enforces consistent code style across teams

### PR Job: Unit Tests
- Minimum 80% code coverage threshold — rejects PRs that decrease coverage
- Race detector enabled (`-race` for Go)
- Results uploaded as artifacts for debugging

### PR Job: Build & Push
- Docker Buildx for multi-platform support
- Layer caching from ECR → 60-80% faster repeat builds
- Image tagged as `pr-<number>-<sha>` (distinct from main builds)
- SLSA Level 2 provenance attestation + SBOM generation

### PR Job: SAST Scan (Trivy)
Two scans run sequentially:
1. **Filesystem scan** (`trivy fs`) — catches secrets leaked in code, Dockerfile misconfigs
2. **Container image scan** (`trivy image`) — scans OS packages and language libraries for CVEs

Both upload SARIF to GitHub Security tab for developer visibility. The pipeline
**fails on CRITICAL CVEs** (unfixed CVEs are suppressed — we can't patch what the OS
vendor hasn't released a fix for). HIGH CVEs generate warnings in the PR comment.

---

## Stage 2: Staging Deployment

Triggered automatically on every push to `main` (i.e., after a PR is merged).

```
merge to main
    │
    ▼
deploy-staging (Helm upgrade --atomic --timeout 5m)
    │
    ▼
smoke-tests (HTTP health + functional + metrics, ~3 min)
    │
    ▼
approve-staging ←── Manual approval gate
    │                (configured in GitHub Environments with required reviewers)
    ▼
deploy-prod-canary
```

### Helm Deployment to Staging
```bash
helm upgrade --install event-ingestion cicd/helm/microservice \
  --namespace staging \
  --set image.repository=<ECR_URI>/event-ingestion \
  --set image.tag=<commit-sha> \
  --set rollout.enabled=false \        # Standard Deployment in staging
  --values cicd/helm/microservice/values-staging.yaml \
  --atomic \                           # Automatic rollback if pods don't become Ready
  --timeout 5m
```

Key flags:
- `--atomic`: if any pod fails to start within 5 minutes, Helm automatically reverts
- `--wait`: blocks until the rollout completes and pods are Ready
- `--timeout 5m`: overall deadline for the deployment

### Smoke Tests
The `cicd/smoke-tests/smoke-test.sh` script validates:
1. All pods are Running and Ready (Kubernetes health)
2. `/health/live` and `/health/ready` return HTTP 200
3. Event ingestion endpoint accepts requests (functional)
4. Prometheus metrics are exposed on `:8080/metrics`

Failure in any test blocks the pipeline and prevents production promotion.

### Approval Gate
The `approve-staging` job uses a GitHub **Environment** named `staging-to-prod`
configured with required reviewers. The pipeline pauses here for up to 24 hours,
waiting for an authorized team member to click "Approve" in the GitHub UI.

Why manual approval?
- Production deploys are irreversible in real time (canary can be stopped, not unwound)
- Approval creates an audit trail (who approved, at what time, with what evidence)
- Forces review of smoke test results before production exposure

---

## Stage 3: Production — Canary Deployment (Argo Rollouts)

### Why Argo Rollouts + Canary?

Traditional blue/green or rolling updates expose all traffic to the new version at once.
At CleverTap's scale (40B events/day), even a 0.1% error rate introduced by a bad deploy
affects millions of events. Canary deployments limit blast radius by exposing only a
fraction of traffic to the new version, with automated rollback if metrics degrade.

### Rollout Strategy: 10% → 50% → 100%

```
Deploy commit SHA → Canary pods (10% traffic)
                          │
                    Prometheus Analysis
                    (error rate + p99 latency)
                          │
                  Pass ───┴─── Fail → ROLLBACK to stable
                    │
            Promote to 50% traffic
                    │
              5-minute bake time
                    │
                  Pass ───┴─── Fail → ROLLBACK
                    │
            Promote to 100% traffic
                    │
             Rollout Complete ✅
```

**Traffic splitting implementation:**
Argo Rollouts uses NGINX Ingress annotations to perform weighted traffic routing:

```yaml
# Argo Rollouts manages these annotations automatically
nginx.ingress.kubernetes.io/canary: "true"
nginx.ingress.kubernetes.io/canary-weight: "10"  # Set to 50, then removed at 100%
```

Two Kubernetes Services are maintained:
- `event-ingestion-stable` → selects old (stable) pods
- `event-ingestion-canary` → selects new (canary) pods

NGINX Ingress routes X% of requests to `canary` based on `canary-weight`.

### Automated Rollback Triggers

The `AnalysisTemplate` (in `cicd/helm/microservice/templates/analysis-template.yaml`)
defines three Prometheus-based checks:

| Metric | Threshold | Window | Max Failures Before Rollback |
|--------|-----------|--------|------------------------------|
| Error rate (5xx/total) | < 1% | 2-minute rate | 2 consecutive failures |
| p99 latency | < 500ms | 2-minute histogram | 2 consecutive failures |
| Success rate (2xx/total) | > 99% | 2-minute rate | 2 consecutive failures |

The analysis runs continuously during canary steps. If any metric fails twice in a row,
Argo Rollouts:
1. Immediately marks the rollout as `Degraded`
2. Routes 100% of traffic back to the stable pods
3. Scales down the canary pods
4. Sends an event to Alertmanager (which pages the on-call engineer)

### Manual Rollback

At any point during the canary, a human can abort:
```bash
kubectl argo rollouts abort event-ingestion -n production
```

Or promote immediately if the analysis results are satisfactory:
```bash
kubectl argo rollouts promote event-ingestion -n production
```

---

## Secret Management — No Secrets in YAML

All secrets follow the **External Secrets Operator + AWS Secrets Manager** pattern:

```
AWS Secrets Manager                   Kubernetes Cluster
─────────────────                     ──────────────────
/clevertap/prod/                      ExternalSecret CR
  event-ingestion/                         │
    kafka-bootstrap-servers  ────────────► Kubernetes Secret
    redis-url                             (synced, refreshed every 1h)
    db-password                                │
                                              │ envFrom.secretRef
                                              ▼
                                    Pod: env KAFKA_BOOTSTRAP_SERVERS=...
```

### Components

1. **AWS Secrets Manager** — single source of truth for all secrets
   - Organized by path: `/clevertap/<env>/<service>/<secret-name>`
   - Automatic rotation configured for database passwords (30-day cycle)
   - CloudTrail audit log of every secret access

2. **External Secrets Operator (ESO)** — installed cluster-wide via Terraform/Helm
   - `ClusterSecretStore` named `aws-secrets-manager` with IRSA role
   - IRSA role has read-only access to the `/clevertap/<env>/` path prefix
   - `ExternalSecret` CRs (defined in `cicd/helm/microservice/templates/external-secret.yaml`)
     sync specific secrets into Kubernetes Secrets

3. **IRSA per service** — each service's ServiceAccount gets its own IAM role
   - Scoped to only the paths that service needs (`/clevertap/<env>/<service-name>/`)
   - No shared credentials between services
   - Principle of least privilege

4. **GitHub Actions → AWS** — no long-lived credentials
   - GitHub OIDC provider registered in AWS IAM
   - Jobs assume an IAM role via `aws-actions/configure-aws-credentials@v4` OIDC
   - Session is scoped to a specific run ID (`role-session-name: github-actions-build-<run-id>`)
   - Access is automatically revoked at the end of the job (token TTL: 1 hour)

### Secret Path Convention

```
/clevertap/<environment>/<service-name>/<secret-name>

Examples:
  /clevertap/prod/event-ingestion/kafka-bootstrap-servers
  /clevertap/prod/event-ingestion/db-password
  /clevertap/staging/event-ingestion/redis-url
  /clevertap/prod/campaign-delivery/api-key
```

### What is NOT a Secret

The following are configurations, not secrets, and belong in Helm values:
- Service URLs (e.g., `kafka.kafka.svc.cluster.local:9092`)
- Feature flags
- Log levels
- Resource limits

---

## Deployment Velocity vs. Safety

| Team Type | Recommended Cadence | Gate Strategy |
|-----------|--------------------|-|
| High-velocity (>10 deploy/day) | Auto-promote if smoke tests pass | Automated canary at 10% for 10 min only |
| Standard (1-5 deploy/day) | Manual approval gate | Standard canary: 10% → 50% → 100% |
| Risk-averse (once/week) | Scheduled deploys with extra bake time | Canary at 10% for 1 hour before promotion |

Pipeline parameters can be tuned per-service via `values-prod.yaml`:
```yaml
rollout:
  canary:
    steps:
      - setWeight: 10
      - pause:
          duration: 1h    # Longer bake time for risk-averse services
```
