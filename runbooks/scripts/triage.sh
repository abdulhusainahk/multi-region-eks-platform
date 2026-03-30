#!/usr/bin/env bash
# =============================================================================
# triage.sh — Event Ingestion Crash Loop Triage Helper
#
# Usage:
#   ./triage.sh [namespace] [service_label]
#
# Defaults:
#   namespace     = production
#   service_label = event-ingestion
#
# This script automates the initial triage steps from:
#   runbooks/pod-crash-looping.md — Steps 1.1 through 1.7
#
# Prerequisites:
#   - kubectl configured with production cluster context
#   - jq installed
#   - Requires read-only permissions to the production namespace
# =============================================================================

set -euo pipefail

# Configurable defaults
NAMESPACE="${1:-production}"
SERVICE="${2:-event-ingestion}"
LOG_LINES=100

# Colour codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

# -----------------------------------------------------------------------------
# Utility functions
# -----------------------------------------------------------------------------

print_header() {
  echo ""
  echo -e "${BLUE}${BOLD}════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}${BOLD}  $1${NC}"
  echo -e "${BLUE}${BOLD}════════════════════════════════════════════════════════${NC}"
}

print_ok()   { echo -e "${GREEN}✅  $1${NC}"; }
print_warn() { echo -e "${YELLOW}⚠️   $1${NC}"; }
print_crit() { echo -e "${RED}🚨  $1${NC}"; }
print_info() { echo -e "    $1"; }

check_kubectl() {
  if ! command -v kubectl &>/dev/null; then
    echo "ERROR: kubectl not found in PATH" >&2
    exit 1
  fi
  if ! kubectl cluster-info --request-timeout=5s &>/dev/null; then
    echo "ERROR: Cannot connect to Kubernetes cluster. Check your kubeconfig." >&2
    exit 1
  fi
}

# Decode exit code to human-readable
decode_exit_code() {
  local code="$1"
  case "$code" in
    0)   echo "Clean exit — app thinks it finished (check for misconfig)" ;;
    1)   echo "Unhandled exception / application error — check logs" ;;
    137) echo "SIGKILL / OOMKilled — memory limit exceeded → scale-out path" ;;
    139) echo "Segfault — binary corruption → rollback immediately" ;;
    143) echo "SIGTERM — graceful shutdown signal (check liveness probe timeouts)" ;;
    *)   echo "Exit code $code — see: https://tldp.org/LDP/abs/html/exitcodes.html" ;;
  esac
}

# -----------------------------------------------------------------------------
# Step 1.2 — Assess scope
# -----------------------------------------------------------------------------
assess_scope() {
  print_header "STEP 1.2 — Pod Status Overview"

  local total running crashing
  total=$(kubectl get pods -n "$NAMESPACE" -l "app=$SERVICE" --no-headers 2>/dev/null | wc -l || echo 0)
  running=$(kubectl get pods -n "$NAMESPACE" -l "app=$SERVICE" --no-headers \
    --field-selector='status.phase=Running' 2>/dev/null | wc -l || echo 0)
  crashing=$(kubectl get pods -n "$NAMESPACE" -l "app=$SERVICE" --no-headers 2>/dev/null \
    | grep -c 'CrashLoopBackOff\|Error\|OOMKilled' || echo 0)

  print_info "Total pods:    $total"
  print_info "Running:       $running"
  print_info "Crashing:      $crashing"

  if [[ "$crashing" -eq 0 ]]; then
    print_ok "No pods in crash loop — alert may have already resolved"
  elif [[ "$crashing" -eq "$total" ]]; then
    print_crit "ALL $total pods are crashing — COMPLETE SERVICE OUTAGE"
    print_warn "Immediate escalation required (see runbook Section 5)"
  elif [[ "$crashing" -gt 2 ]]; then
    print_warn "$crashing/$total pods crashing — significant degradation"
  else
    print_warn "$crashing/$total pods crashing — partial degradation"
  fi

  echo ""
  echo "Pod list (sorted by restart count):"
  kubectl get pods -n "$NAMESPACE" -l "app=$SERVICE" \
    --sort-by='.status.containerStatuses[0].restartCount' \
    -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount,AGE:.metadata.creationTimestamp' \
    2>/dev/null || echo "(no pods found)"
}

# -----------------------------------------------------------------------------
# Step 1.3 — Check exit codes and last state
# -----------------------------------------------------------------------------
check_crash_reason() {
  print_header "STEP 1.3 — Crash Reasons"

  local crashing_pods
  crashing_pods=$(kubectl get pods -n "$NAMESPACE" -l "app=$SERVICE" --no-headers 2>/dev/null \
    | grep 'CrashLoopBackOff\|Error\|OOMKilled' | awk '{print $1}' || true)

  if [[ -z "$crashing_pods" ]]; then
    print_ok "No pods in CrashLoopBackOff state"
    return
  fi

  for pod in $crashing_pods; do
    echo ""
    echo -e "${BOLD}Pod: $pod${NC}"
    local exit_code
    exit_code=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath=\
'{.status.containerStatuses[0].lastState.terminated.exitCode}' 2>/dev/null || echo "unknown")
    local reason
    reason=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath=\
'{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || echo "unknown")

    print_info "Exit code: $exit_code — $(decode_exit_code "$exit_code")"
    print_info "Reason:    $reason"

    if [[ "$exit_code" == "137" ]]; then
      print_crit "OOMKilled — go to Decision Tree [B] SCALE-OUT"
    elif [[ "$exit_code" == "139" ]]; then
      print_crit "Segfault — go to Decision Tree [A] ROLLBACK immediately"
    fi
  done
}

# -----------------------------------------------------------------------------
# Step 1.4 — Fetch recent crash logs
# -----------------------------------------------------------------------------
fetch_logs() {
  print_header "STEP 1.4 — Recent Crash Logs"

  local crashing_pod
  crashing_pod=$(kubectl get pods -n "$NAMESPACE" -l "app=$SERVICE" --no-headers 2>/dev/null \
    | grep 'CrashLoopBackOff\|Error\|OOMKilled' | head -1 | awk '{print $1}' || true)

  if [[ -z "$crashing_pod" ]]; then
    print_ok "No crashing pods to pull logs from"
    return
  fi

  echo "Fetching previous container logs from: $crashing_pod"
  echo "(Last $LOG_LINES lines)"
  echo "---"
  kubectl logs -n "$NAMESPACE" "$crashing_pod" --previous --tail="$LOG_LINES" 2>&1 \
    | grep -E 'ERROR|error|FATAL|fatal|panic|exception|OOMKilled|killed|timeout|refused' \
    | tail -30 \
    || echo "(no error lines found in recent logs)"
  echo "---"
  print_info "Full logs: kubectl logs -n $NAMESPACE $crashing_pod --previous"
}

# -----------------------------------------------------------------------------
# Step 1.5 — Check recent deployments
# -----------------------------------------------------------------------------
check_deployments() {
  print_header "STEP 1.5 — Recent Deployments"

  local last_deploy_time
  last_deploy_time=$(kubectl get replicasets -n "$NAMESPACE" \
    -l "app=$SERVICE" \
    --sort-by='.metadata.creationTimestamp' \
    -o jsonpath='{.items[-1:].metadata.creationTimestamp}' 2>/dev/null || echo "unknown")

  echo "Most recent ReplicaSet created: $last_deploy_time"
  echo ""
  echo "Deployment rollout history:"
  kubectl rollout history deployment/"$SERVICE" -n "$NAMESPACE" 2>/dev/null \
    || echo "(deployment $SERVICE not found in namespace $NAMESPACE)"

  echo ""
  print_info "Compare deploy time vs. alert fire time to determine causality"
  print_info "To rollback: kubectl rollout undo deployment/$SERVICE -n $NAMESPACE"
}

# -----------------------------------------------------------------------------
# Step 1.6 — Check dependencies
# -----------------------------------------------------------------------------
check_dependencies() {
  print_header "STEP 1.6 — Dependency Health"

  # Kafka
  echo "Checking Kafka connectivity..."
  if kubectl exec -n "$NAMESPACE" \
    "$(kubectl get pods -n "$NAMESPACE" -l "app=$SERVICE" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" -- \
    sh -c "nc -zv \"\${KAFKA_BOOTSTRAP_SERVERS:-kafka-broker.kafka.svc.cluster.local:9092}\" 2>&1" \
    &>/dev/null 2>&1; then
    print_ok "Kafka reachable"
  else
    print_warn "Cannot verify Kafka connectivity from pod (pod may be in init state)"
    print_info "Check manually: kubectl exec -n $NAMESPACE <pod> -- nc -zv kafka-broker.kafka.svc.cluster.local 9092"
  fi

  # Check if other services are also unhealthy (blast radius)
  echo ""
  echo "Other non-Running pods in $NAMESPACE namespace:"
  kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
    | grep -v 'Running\|Completed\|Succeeded' \
    || print_ok "All other pods in $NAMESPACE are healthy"
}

# -----------------------------------------------------------------------------
# Step 1.7 — Check resource utilization
# -----------------------------------------------------------------------------
check_resources() {
  print_header "STEP 1.7 — Resource Utilisation"

  echo "Memory and CPU usage (requires metrics-server):"
  kubectl top pods -n "$NAMESPACE" -l "app=$SERVICE" \
    --sort-by=memory 2>/dev/null \
    || echo "(metrics-server not available — check CloudWatch or Grafana for memory usage)"

  echo ""
  echo "Resource limits and requests:"
  kubectl get deployment "$SERVICE" -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '.spec.template.spec.containers[] | "Container: \(.name)\n  Requests: CPU=\(.resources.requests.cpu // "none") Memory=\(.resources.requests.memory // "none")\n  Limits:   CPU=\(.resources.limits.cpu // "none") Memory=\(.resources.limits.memory // "none")"' \
    || echo "(could not read resource specs)"
}

# -----------------------------------------------------------------------------
# Summary and recommendations
# -----------------------------------------------------------------------------
print_summary() {
  print_header "TRIAGE SUMMARY"

  echo -e "${BOLD}Next Steps Based on Findings:${NC}"
  echo ""
  echo "  [A] Recent deployment detected → Try rollback first:"
  echo "      kubectl rollout undo deployment/$SERVICE -n $NAMESPACE"
  echo ""
  echo "  [B] OOMKilled (exit 137) → Scale out + increase limits:"
  echo "      kubectl scale deployment $SERVICE -n $NAMESPACE --replicas=12"
  echo "      kubectl patch deployment $SERVICE -n $NAMESPACE --type=json \\"
  echo "        -p='[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/limits/memory\",\"value\":\"4Gi\"}]'"
  echo ""
  echo "  [C] Dependency down → Check dependency runbook and escalate"
  echo ""
  echo -e "${BOLD}Dashboards:${NC}"
  echo "  Grafana: https://grafana.clevertap.com/d/event-ingestion/event-ingestion-overview"
  echo "  Logs:    https://grafana.clevertap.com/explore (datasource: Loki)"
  echo ""
  echo -e "${BOLD}Full Runbook:${NC}"
  echo "  https://github.com/clevertap/infra/blob/main/runbooks/pod-crash-looping.md"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  echo ""
  echo -e "${BOLD}CleverTap — Event Ingestion Crash Loop Triage${NC}"
  echo -e "Namespace: ${NAMESPACE} | Service label: app=${SERVICE}"
  echo -e "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  check_kubectl
  assess_scope
  check_crash_reason
  fetch_logs
  check_deployments
  check_dependencies
  check_resources
  print_summary
}

main "$@"
