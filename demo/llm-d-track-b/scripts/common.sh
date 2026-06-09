#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Common functions and environment defaults for the Track B demo.
#
# Source this file from other scripts:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPT_DIR/../common.sh"
# ---------------------------------------------------------------------------

set -euo pipefail

# -- Environment defaults ---------------------------------------------------
# TRACK_B_DIR = root of the praxis checkout (track-b-benchmarking branch).
# EPP_BIN / SIM_BIN can be overridden if cloned elsewhere.

missing=""
if [[ -z "${TRACK_B_DIR:-}" ]]; then missing="TRACK_B_DIR"; fi
if [[ -z "${EPP_BIN:-}" ]]; then missing="${missing:+$missing, }EPP_BIN"; fi
if [[ -z "${SIM_BIN:-}" ]]; then missing="${missing:+$missing, }SIM_BIN"; fi

if [[ -n "$missing" ]]; then
  cat >&2 <<EOF

Missing: $missing

This script requires three environment variables. Set all three, then re-run.

  # 1. TRACK_B_DIR — Praxis checkout (track-b-benchmarking branch)
  #    Clone and build, or point to an existing checkout:
  git clone -b track-b-benchmarking https://github.com/nerdalert/praxis.git praxis-track-b
  cd praxis-track-b
  cargo build --release -p praxis --features ext-proc
  export TRACK_B_DIR="\$(pwd)"
  cd ..

  # 2. EPP_BIN — Go EPP binary
  #    Clone and build, or point to an existing binary:
  git clone https://github.com/llm-d/llm-d-router.git
  cd llm-d-router && go build -o bin/epp ./cmd/epp && cd ..
  export EPP_BIN="\$(pwd)/llm-d-router/bin/epp"

  # 3. SIM_BIN — llm-d-inference-sim binary
  #    Clone and build, or point to an existing binary:
  git clone https://github.com/llm-d/llm-d-inference-sim.git
  cd llm-d-inference-sim && make build && cd ..
  export SIM_BIN="\$(pwd)/llm-d-inference-sim/bin/llm-d-inference-sim"

EOF
  exit 1
fi

export PRAXIS_BIN="${PRAXIS_BIN:-${TRACK_B_DIR}/target/release/praxis}"
export EPP_BIN
export SIM_BIN

# Demo scripts directory (contains configs/, manifests/)
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPTS_DIR
DEMO_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
export DEMO_DIR
export CONFIGS_DIR="${SCRIPTS_DIR}/configs"
export MANIFESTS_DIR="${DEMO_DIR}/manifests"

# Ports
export SIM_PORT="${SIM_PORT:-18080}"
export PRAXIS_PORT="${PRAXIS_PORT:-18091}"
export EPP_GRPC_PORT="${EPP_GRPC_PORT:-9002}"
export EPP_HEALTH_PORT="${EPP_HEALTH_PORT:-9003}"
export EPP_METRICS_PORT="${EPP_METRICS_PORT:-9090}"

# Process tracking
SIM_PID=""
EPP_PID=""
PRAXIS_PID=""

# -- Output helpers (matches Track A style) ---------------------------------

say() {
  printf '[track-b] %s\n' "$*"
}

header() {
  printf '\n\033[32m[track-b] %s\033[0m\n' "$*"
}

break_line() {
  printf '\n'
}

fail() {
  printf '\033[31m[track-b] FAIL: %s\033[0m\n' "$*"
}

pass() {
  printf '\033[32m[track-b]   ✓ %s\033[0m\n' "$*"
}

# -- Process management -----------------------------------------------------

cleanup_processes() {
  say "cleaning up..."
  if [[ -n "$PRAXIS_PID" ]]; then kill "$PRAXIS_PID" 2>/dev/null || true; fi
  if [[ -n "$EPP_PID" ]]; then kill "$EPP_PID" 2>/dev/null || true; fi
  if [[ -n "$SIM_PID" ]]; then kill "$SIM_PID" 2>/dev/null || true; fi
  wait 2>/dev/null || true
  say "all processes stopped"
}

trap cleanup_processes EXIT

wait_for_port() {
  local label="$1" port="$2" timeout="${3:-30}"
  say "waiting for $label on port $port..."
  for _ in $(seq 1 "$timeout"); do
    if (echo >"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; then
      say "$label ready on port $port"
      return 0
    fi
    sleep 0.5
  done
  fail "$label did not become ready on port $port"
  return 1
}

wait_for_http() {
  local label="$1" url="$2" timeout="${3:-30}"
  say "waiting for $label at $url..."
  for _ in $(seq 1 "$timeout"); do
    if curl -sf "$url" >/dev/null 2>&1; then
      say "$label ready"
      return 0
    fi
    sleep 0.5
  done
  fail "$label did not become ready"
  return 1
}

# -- Start services ----------------------------------------------------------

start_simulator() {
  local model="${1:-test-model}"
  header "Starting inference simulator (model=$model)"
  "$SIM_BIN" --model "$model" --served-model-name "$model" \
    --port "$SIM_PORT" --logtostderr=true \
    > /tmp/track-b-demo-sim.log 2>&1 &
  SIM_PID=$!
  wait_for_http "simulator" "http://127.0.0.1:${SIM_PORT}/health"
}

start_epp() {
  header "Starting Go EPP on gRPC port $EPP_GRPC_PORT"
  local epp_tmp
  epp_tmp=$(mktemp -d)
  local endpoints="${CONFIGS_DIR}/epp-endpoints.yaml"
  sed "s|PLACEHOLDER_ENDPOINTS_PATH|${endpoints}|" \
    "${CONFIGS_DIR}/epp-config.yaml" > "$epp_tmp/epp-config.yaml"

  "$EPP_BIN" \
    --pool-name bench-pool \
    --config-file "$epp_tmp/epp-config.yaml" \
    --grpc-port "$EPP_GRPC_PORT" \
    --grpc-health-port "$EPP_HEALTH_PORT" \
    --metrics-port "$EPP_METRICS_PORT" \
    --secure-serving=false --health-checking=false \
    --tracing=false --metrics-endpoint-auth=false \
    > /tmp/track-b-demo-epp.log 2>&1 &
  EPP_PID=$!
  wait_for_port "Go EPP" "$EPP_GRPC_PORT"
}

start_praxis() {
  header "Starting Praxis on port $PRAXIS_PORT"
  local config="${CONFIGS_DIR}/praxis.yaml"
  PRAXIS_CONFIG="$config" "$PRAXIS_BIN" \
    > /tmp/track-b-demo-praxis.log 2>&1 &
  PRAXIS_PID=$!
  wait_for_port "Praxis" "$PRAXIS_PORT"
}

# -- Request helpers ---------------------------------------------------------

send_chat_request() {
  local model="$1"
  local content="${2:-hello from Track B demo}"
  curl -s "http://127.0.0.1:${PRAXIS_PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"${content}\"}],\"max_tokens\":10}"
}

send_chat_request_with_status() {
  local model="$1"
  local content="${2:-hello from Track B demo}"
  curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
    "http://127.0.0.1:${PRAXIS_PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"${content}\"}],\"max_tokens\":10}"
}

check_http_status() {
  local raw="$1"
  local expected="$2"
  local label="$3"
  local actual
  actual="$(printf '%s\n' "$raw" | awk -F: '/^HTTP_STATUS:/ {print $2}' | tail -1)"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label -> HTTP $actual"
    return 0
  else
    fail "$label -> HTTP $actual (expected $expected)"
    return 1
  fi
}

show_epp_request_log() {
  say "Go EPP request log:"
  grep -E "EPP received request|EPP sent request" /tmp/track-b-demo-epp.log 2>/dev/null | tail -4 | while read -r line; do
    say "  $line"
  done
}
