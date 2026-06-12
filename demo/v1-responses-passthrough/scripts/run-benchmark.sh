#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

BENCH_RUNS="${BENCH_RUNS:-3}"
BENCH_REQUESTS="${BENCH_REQUESTS:-200}"
BENCH_CONCURRENCY="${BENCH_CONCURRENCY:-8}"
BENCH_WARMUP="${BENCH_WARMUP:-20}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$DEMO_DIR/artifacts/$RUN_ID}"
RESULTS_OUTPUT="${RESULTS_OUTPUT:-$ARTIFACT_DIR/results.md}"

WORK="$(mktemp -d)"
LOG_DIR="$ARTIFACT_DIR/logs"
mkdir -p "$LOG_DIR" "$ARTIFACT_DIR/raw" "$ARTIFACT_DIR/configs"

cleanup() {
  cleanup_processes
  rm -rf "$WORK"
}
trap cleanup EXIT

check_prereqs
build_praxis
start_mock_backends

python3 "$SCRIPT_DIR/benchmark_client.py" metadata \
  --praxis-dir "$PRAXIS_DIR" \
  --output "$ARTIFACT_DIR/metadata.json"

profiles=(
  direct-backend
  praxis-format-route
  praxis-model-rewrite-noop
  praxis-model-rewrite-alias
  praxis-full-flow
)
workloads=(
  small-json
  streaming-sse
  payload-16kib
  payload-64kib
  payload-256kib
  tools
  function-call-output
)

run_profile() {
  local profile="$1"
  local praxis_pid=""
  local model="backend-native"
  local store="false"

  if [[ "$profile" != "direct-backend" ]]; then
    local config_profile="${profile#praxis-}"
    local config="$ARTIFACT_DIR/configs/$profile.yaml"
    local database_path=""
    if [[ "$profile" == "praxis-full-flow" ]]; then
      database_path="$ARTIFACT_DIR/full-flow.db"
      rm -f "$database_path"
      store="true"
    fi
    write_praxis_config "$config_profile" "$config" "$PRAXIS_PORT" "$database_path"
    start_praxis "$profile" "$config" "$PRAXIS_PORT"
    praxis_pid="$LAST_BG_PID"
  fi

  if [[ "$profile" == "praxis-model-rewrite-alias" ]]; then
    model="codex-mini-latest"
  fi

  local workload run url output
  for workload in "${workloads[@]}"; do
    if [[ "$profile" == "direct-backend" ]]; then
      if [[ "$workload" == "streaming-sse" ]]; then
        url="http://127.0.0.1:${STREAM_BACKEND_PORT}/v1/responses"
      else
        url="http://127.0.0.1:${RESPONSES_BACKEND_PORT}/v1/responses"
      fi
    else
      url="http://127.0.0.1:${PRAXIS_PORT}/v1/responses"
    fi

    for run in $(seq 1 "$BENCH_RUNS"); do
      output="$ARTIFACT_DIR/raw/${profile}__${workload}__run-${run}.json"
      python3 "$SCRIPT_DIR/benchmark_client.py" run \
        --profile "$profile" \
        --workload "$workload" \
        --url "$url" \
        --model "$model" \
        --store "$store" \
        --requests "$BENCH_REQUESTS" \
        --concurrency "$BENCH_CONCURRENCY" \
        --warmup "$BENCH_WARMUP" \
        --output "$output"
    done
  done

  if [[ -n "$praxis_pid" ]]; then
    stop_bg "$praxis_pid"
  fi
}

log_section "Running benchmark profiles"
for profile in "${profiles[@]}"; do
  log "Profile: $profile"
  run_profile "$profile"
done

python3 "$SCRIPT_DIR/benchmark_client.py" summarize \
  --artifact-dir "$ARTIFACT_DIR" \
  --output "$RESULTS_OUTPUT"

log "Raw artifacts: $ARTIFACT_DIR"
log "Summary: $RESULTS_OUTPUT"
