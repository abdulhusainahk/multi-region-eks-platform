#!/usr/bin/env bash
# =============================================================================
# smoke-test.sh — Automated smoke tests for staging validation
#
# Runs after every staging Helm deployment to validate:
#   1. Health endpoints respond correctly
#   2. Core API endpoints are reachable (functional smoke tests)
#   3. Metrics endpoint exposes Prometheus metrics
#   4. Pod readiness (all pods are in Ready state)
#
# Environment variables (set by CI/CD pipeline):
#   SERVICE_NAME  — Kubernetes service/deployment name
#   NAMESPACE     — Kubernetes namespace (default: staging)
#   BASE_URL      — Base URL for HTTP tests (e.g. https://staging.clevertap.com)
#   SMOKE_TIMEOUT — Per-test timeout in seconds (default: 30)
#
# Exit codes:
#   0 — All tests passed
#   1 — One or more tests failed
#
# Results written to: /tmp/smoke-test-results.json
# =============================================================================

set -euo pipefail

# Configuration
SERVICE_NAME="${SERVICE_NAME:-event-ingestion}"
NAMESPACE="${NAMESPACE:-staging}"
BASE_URL="${BASE_URL:-https://staging.clevertap.com}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-30}"
RESULTS_FILE="/tmp/smoke-test-results.json"

# Colour output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
declare -a TEST_RESULTS=()

# =============================================================================
# Utility functions
# =============================================================================

print_header() {
  echo ""
  echo -e "${BLUE}${BOLD}══════════════════════════════════════════${NC}"
  echo -e "${BLUE}${BOLD}  $1${NC}"
  echo -e "${BLUE}${BOLD}══════════════════════════════════════════${NC}"
}

pass() {
  local test_name="$1"
  local detail="${2:-}"
  echo -e "${GREEN}✅ PASS${NC}: $test_name ${detail:+($detail)}"
  PASS_COUNT=$((PASS_COUNT + 1))
  TEST_RESULTS+=("{\"test\":\"$test_name\",\"status\":\"pass\",\"detail\":\"$detail\"}")
}

fail() {
  local test_name="$1"
  local detail="${2:-}"
  echo -e "${RED}❌ FAIL${NC}: $test_name ${detail:+($detail)}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  TEST_RESULTS+=("{\"test\":\"$test_name\",\"status\":\"fail\",\"detail\":\"$detail\"}")
}

warn() {
  local test_name="$1"
  local detail="${2:-}"
  echo -e "${YELLOW}⚠️  WARN${NC}: $test_name ${detail:+($detail)}"
  TEST_RESULTS+=("{\"test\":\"$test_name\",\"status\":\"warn\",\"detail\":\"$detail\"}")
}

http_get() {
  local url="$1"
  local timeout="${SMOKE_TIMEOUT}"

  local actual_status
  actual_status=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time "$timeout" \
    --retry 3 \
    --retry-delay 5 \
    --retry-connrefused \
    "$url" 2>/dev/null || echo "000")

  echo "$actual_status"
}

http_get_body() {
  local url="$1"
  curl -s --max-time "$SMOKE_TIMEOUT" --retry 2 "$url" 2>/dev/null || echo ""
}

# =============================================================================
# Test Suite 1: Kubernetes Pod Health
# =============================================================================
test_pod_readiness() {
  print_header "Test Suite 1: Kubernetes Pod Readiness"

  # 1.1 — All pods are in Running state
  local total_pods running_pods not_running
  total_pods=$(kubectl get pods -n "$NAMESPACE" -l "app=$SERVICE_NAME" \
    --no-headers 2>/dev/null | wc -l || echo 0)
  running_pods=$(kubectl get pods -n "$NAMESPACE" -l "app=$SERVICE_NAME" \
    --no-headers 2>/dev/null | grep -c Running || echo 0)
  not_running=$((total_pods - running_pods))

  if [[ "$total_pods" -eq 0 ]]; then
    fail "pods-exist" "No pods found for service $SERVICE_NAME in namespace $NAMESPACE"
    return
  fi

  if [[ "$not_running" -gt 0 ]]; then
    fail "all-pods-running" "$not_running/$total_pods pods are not Running"
  else
    pass "all-pods-running" "$running_pods/$total_pods pods Running"
  fi

  # 1.2 — All pods are Ready (readiness probe passing)
  local ready_pods
  ready_pods=$(kubectl get pods -n "$NAMESPACE" -l "app=$SERVICE_NAME" \
    -o jsonpath='{.items[*].status.containerStatuses[0].ready}' 2>/dev/null \
    | tr ' ' '\n' | grep -c true || echo 0)

  if [[ "$ready_pods" -eq "$total_pods" ]]; then
    pass "all-pods-ready" "$ready_pods/$total_pods pods Ready"
  else
    fail "all-pods-ready" "Only $ready_pods/$total_pods pods are Ready"
  fi

  # 1.3 — No recent restarts (within last 5 minutes)
  local restart_count
  restart_count=$(kubectl get pods -n "$NAMESPACE" -l "app=$SERVICE_NAME" \
    -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' 2>/dev/null \
    | tr ' ' '\n' | awk '{s+=$1} END {print s+0}')

  if [[ "$restart_count" -gt 0 ]]; then
    warn "no-recent-restarts" "$restart_count total restarts detected (may be from previous deploy)"
  else
    pass "no-recent-restarts" "0 restart count"
  fi
}

# =============================================================================
# Test Suite 2: HTTP Health Endpoints
# =============================================================================
test_health_endpoints() {
  print_header "Test Suite 2: HTTP Health Endpoints"

  # 2.1 — Liveness probe endpoint
  local status
  status=$(http_get "${BASE_URL}/api/health/live")
  if [[ "$status" == "200" ]]; then
    pass "liveness-endpoint" "HTTP $status"
  else
    fail "liveness-endpoint" "Expected HTTP 200, got HTTP $status"
  fi

  # 2.2 — Readiness probe endpoint
  status=$(http_get "${BASE_URL}/api/health/ready")
  if [[ "$status" == "200" ]]; then
    pass "readiness-endpoint" "HTTP $status"
  else
    fail "readiness-endpoint" "Expected HTTP 200, got HTTP $status"
  fi

  # 2.3 — Version endpoint (confirms correct image was deployed)
  local version_body
  version_body=$(http_get_body "${BASE_URL}/api/version")
  if echo "$version_body" | grep -q '"version"'; then
    pass "version-endpoint" "Response contains version field"
  else
    warn "version-endpoint" "Version endpoint did not return expected JSON"
  fi
}

# =============================================================================
# Test Suite 3: Core Functional Smoke Tests
# =============================================================================
test_functional() {
  print_header "Test Suite 3: Functional Smoke Tests"

  # 3.1 — Event ingestion endpoint accepts a well-formed request
  local ingest_status
  ingest_status=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time "$SMOKE_TIMEOUT" \
    --retry 2 \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-CleverTap-Account-Id: smoke-test" \
    -d '{"d":[{"identity":"smoke-test-user","evtName":"smoke_test_event","evtData":{"source":"ci"}}]}' \
    "${BASE_URL}/api/1/upload" 2>/dev/null || echo "000")

  # Accept 200 (success) or 401 (auth required — service is up but rejects unauthenticated requests)
  if [[ "$ingest_status" == "200" || "$ingest_status" == "401" || "$ingest_status" == "403" ]]; then
    pass "event-ingest-endpoint" "HTTP $ingest_status (service reachable)"
  elif [[ "$ingest_status" == "000" ]]; then
    fail "event-ingest-endpoint" "Connection failed (curl error)"
  else
    fail "event-ingest-endpoint" "Unexpected HTTP $ingest_status"
  fi

  # 3.2 — Service returns correct Content-Type headers
  local content_type
  content_type=$(curl -s -o /dev/null -w "%{content_type}" \
    --max-time "$SMOKE_TIMEOUT" \
    "${BASE_URL}/api/health/live" 2>/dev/null || echo "")

  if echo "$content_type" | grep -q "application/json"; then
    pass "content-type-json" "$content_type"
  else
    warn "content-type-json" "Expected application/json, got $content_type"
  fi
}

# =============================================================================
# Test Suite 4: Metrics and Observability
# =============================================================================
test_observability() {
  print_header "Test Suite 4: Observability"

  # 4.1 — Prometheus metrics endpoint is accessible
  local metrics_status
  metrics_status=$(http_get "${BASE_URL}/api/metrics")

  if [[ "$metrics_status" == "200" ]]; then
    pass "metrics-endpoint" "HTTP $metrics_status"
  else
    # Not a hard failure — metrics port may not be exposed externally
    warn "metrics-endpoint" "HTTP $metrics_status (may not be exposed externally)"
  fi

  # 4.2 — Pod-level Prometheus metrics via kubectl port-forward
  local pod_name
  pod_name=$(kubectl get pods -n "$NAMESPACE" -l "app=$SERVICE_NAME" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$pod_name" ]]; then
    warn "pod-metrics" "No pod found to check metrics directly"
    return
  fi

  # Port-forward in background
  kubectl port-forward -n "$NAMESPACE" "$pod_name" 18080:8080 &>/dev/null &
  local PF_PID=$!
  sleep 3  # Give port-forward time to establish

  local pod_metrics
  pod_metrics=$(http_get "http://localhost:18080/metrics")

  kill "$PF_PID" 2>/dev/null || true

  if [[ "$pod_metrics" == "200" ]]; then
    pass "pod-metrics" "Prometheus metrics exposed on :8080/metrics"
  else
    fail "pod-metrics" "HTTP $pod_metrics from pod metrics endpoint"
  fi
}

# =============================================================================
# Write results and print summary
# =============================================================================
write_results() {
  local total=$((PASS_COUNT + FAIL_COUNT))
  local result_json

  # Build JSON array from results
  local joined_results
  joined_results=$(IFS=','; echo "${TEST_RESULTS[*]}")

  result_json=$(cat <<EOF
{
  "service": "${SERVICE_NAME}",
  "namespace": "${NAMESPACE}",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "summary": {
    "total": ${total},
    "passed": ${PASS_COUNT},
    "failed": ${FAIL_COUNT}
  },
  "tests": [${joined_results}]
}
EOF
)

  echo "$result_json" > "$RESULTS_FILE"

  echo ""
  echo -e "${BOLD}══════════════════════════════════════════${NC}"
  echo -e "${BOLD}Smoke Test Summary${NC}"
  echo -e "Service:  ${SERVICE_NAME} (${NAMESPACE})"
  echo -e "Passed:   ${GREEN}${PASS_COUNT}${NC}"
  echo -e "Failed:   ${RED}${FAIL_COUNT}${NC}"
  echo -e "Total:    ${total}"
  echo -e "${BOLD}══════════════════════════════════════════${NC}"

  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo -e "${RED}❌ SMOKE TESTS FAILED — blocking deployment promotion${NC}"
    echo ""
    echo "Results written to: $RESULTS_FILE"
    exit 1
  else
    echo -e "${GREEN}✅ ALL SMOKE TESTS PASSED${NC}"
    echo ""
    echo "Results written to: $RESULTS_FILE"
    exit 0
  fi
}

# =============================================================================
# Main
# =============================================================================
main() {
  echo ""
  echo -e "${BOLD}CleverTap Staging Smoke Tests${NC}"
  echo -e "Service: ${SERVICE_NAME} | Namespace: ${NAMESPACE} | Base URL: ${BASE_URL}"
  echo -e "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # Check prerequisites
  if ! command -v kubectl &>/dev/null; then
    echo "ERROR: kubectl not found. Ensure kubeconfig is configured." >&2
    exit 1
  fi
  if ! command -v curl &>/dev/null; then
    echo "ERROR: curl not found." >&2
    exit 1
  fi

  test_pod_readiness
  test_health_endpoints
  test_functional
  test_observability
  write_results
}

main "$@"
