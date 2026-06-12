#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

OUT="${1:-}"
WORK="$(mktemp -d)"
LOG_DIR="$WORK/logs"
mkdir -p "$LOG_DIR"

cleanup() {
  cleanup_processes
  rm -rf "$WORK"
}
trap cleanup EXIT

check_prereqs
build_praxis

log_section "Starting deterministic backends"
start_mock_backends

CONFIG="$WORK/smoke.yaml"
write_praxis_config smoke "$CONFIG" "$PRAXIS_PORT"

log_section "Starting Praxis"
start_praxis smoke "$CONFIG" "$PRAXIS_PORT"

log_section "Running smoke scenarios"
client_args=(
  --praxis-url "http://127.0.0.1:${PRAXIS_PORT}"
  --stream-backend-url "http://127.0.0.1:${STREAM_BACKEND_PORT}"
)
if [[ -n "$OUT" ]]; then
  client_args+=(--markdown-output "$OUT")
fi
python3 "$SCRIPT_DIR/smoke_client.py" "${client_args[@]}"

if [[ -n "$OUT" ]]; then
  {
    echo
    echo "## Generated Praxis Config"
    echo
    echo '```yaml'
    cat "$CONFIG"
    echo '```'
    echo
    echo "## Claim Boundaries"
    echo
    echo "- This proves local request-path behavior with deterministic mock backends."
    echo "- It does not measure or claim model-serving, GPU, or production performance."
    echo "- Praxis does not execute client function tools in this passthrough profile."
    echo "- Token usage is present only in mock responses; this demo does not claim a deployable token-usage filter."
  } >>"$OUT"
fi

log "Smoke validation complete."

