#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Common functions and environment defaults for the llm-d Praxis demo.
#
# Source this file from other scripts:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPT_DIR/common.sh"
# ---------------------------------------------------------------------------

set -euo pipefail

# -- Environment defaults ---------------------------------------------------

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRAXIS_DIR="${PRAXIS_DIR:-/home/ubuntu/praxxis/llm-d/praxis}"
LLM_D_INFERENCE_SIM_DIR="${LLM_D_INFERENCE_SIM_DIR:-/home/ubuntu/praxxis/llm-d/llm-d-inference-sim}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-praxis-llmd-demo}"
PRAXIS_NODE_PORT="${PRAXIS_NODE_PORT:-30081}"
PRAXIS_IMAGE="${PRAXIS_IMAGE:-praxis-epp:dev}"
SIM_IMAGE="${SIM_IMAGE:-ghcr.io/llm-d/llm-d-inference-sim:dev}"
MANIFESTS_DIR="${DEMO_DIR}/manifests"

# -- Helper functions -------------------------------------------------------

log() {
  echo "[llm-d-demo] $*"
}

log_section() {
  echo
  echo "================================================================"
  echo "  $*"
  echo "================================================================"
  echo
}

wait_for_pods() {
  local label="$1"
  local timeout="${2:-120s}"
  log "Waiting for pods with label $label ..."
  kubectl wait --for=condition=ready pod -l "$label" --timeout="$timeout"
}

wait_for_port() {
  local port="$1"
  local name="$2"
  local max_wait="${3:-60}"
  log "Waiting for $name on localhost:$port ..."
  for _ in $(seq 1 "$max_wait"); do
    if (echo >"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; then
      log "$name is ready on port $port"
      return 0
    fi
    sleep 1
  done
  echo "ERROR: Timed out waiting for $name on localhost:$port" >&2
  return 1
}

wait_for_metrics_scrape() {
  local seconds="${1:-5}"
  log "Waiting ${seconds}s for metrics scrape cycle ..."
  sleep "$seconds"
}

send_chat_request() {
  local model="$1"
  local content="${2:-hello}"
  curl -s http://localhost:"${PRAXIS_NODE_PORT}"/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"${content}\"}]}"
}

send_chat_request_with_status() {
  local model="$1"
  local content="${2:-hello}"
  curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
    http://localhost:"${PRAXIS_NODE_PORT}"/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"${content}\"}]}"
}

check_http_status() {
  local raw="$1"
  local expected="$2"
  local actual
  actual="$(printf '%s\n' "$raw" | awk -F: '/^HTTP_STATUS:/ {print $2}' | tail -1)"
  if [[ "$actual" == "$expected" ]]; then
    log "PASS: HTTP status $actual (expected $expected)"
    return 0
  else
    log "FAIL: HTTP status $actual (expected $expected)"
    return 1
  fi
}

apply_manifests() {
  local manifest="$1"
  log "Applying $manifest ..."
  kubectl apply -f "$manifest"
}

show_praxis_logs() {
  local lines="${1:-20}"
  log "Praxis logs (last $lines lines):"
  kubectl logs -l app=praxis --tail="$lines" 2>/dev/null || true
}
