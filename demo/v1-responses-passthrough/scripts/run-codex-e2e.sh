#!/usr/bin/env bash
# Codex CLI end-to-end test through Praxis /v1/responses passthrough.
#
# Proves:
#   1. Codex sends model "codex-demo-client-name" to Praxis.
#   2. Praxis rewrites it to "llama-3.3-70b".
#   3. A deterministic SSE backend returns an exec_command function call.
#   4. Codex executes it and creates proof.txt with "praxis-codex-e2e".
#   5. Codex sends matching function_call_output through Praxis.
#   6. Backend returns a final response.
#   7. Codex exits successfully.
#
# Usage:
#   ./scripts/run-codex-e2e.sh
#   KEEP_ARTIFACTS=1 SKIP_BUILD=1 ./scripts/run-codex-e2e.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

CODEX_BACKEND_PORT="${CODEX_BACKEND_PORT:-18285}"

require_command codex

CODEX_VERSION="$(codex --version 2>/dev/null || echo 'unknown')"
log "Codex CLI version: $CODEX_VERSION"

# ---------------------------------------------------------------------------
# Workspace
# ---------------------------------------------------------------------------

WORK="$HOME/codex-e2e-$(date -u +%Y%m%dT%H%M%SZ)-$$"
LOG_DIR="$WORK/logs"
mkdir -p "$WORK/workspace" "$WORK/codex-home" "$LOG_DIR"

log "Artifacts: $WORK"

cleanup() {
  local exit_code=$?
  cleanup_processes
  if [[ "${KEEP_ARTIFACTS:-0}" == "1" || $exit_code -ne 0 ]]; then
    log "Artifacts preserved: $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

check_prereqs
build_praxis

# ---------------------------------------------------------------------------
# Start mock backend
# ---------------------------------------------------------------------------

log_section "Starting Codex tool-loop mock backend"

start_bg codex-tool-loop-backend \
  env LOG_DIR="$LOG_DIR" \
  python3 "$DEMO_DIR/mock-scripts/codex-tool-loop-mock.py" \
  --port "$CODEX_BACKEND_PORT" --name codex-tool-loop-backend

wait_for_port "$CODEX_BACKEND_PORT" "Codex tool-loop mock"

# ---------------------------------------------------------------------------
# Start Praxis with model rewrite
# ---------------------------------------------------------------------------

log_section "Starting Praxis with model rewrite"

CONFIG="$WORK/praxis-codex-e2e.yaml"
cat > "$CONFIG" <<YAML
listeners:
  - name: codex-e2e
    address: "127.0.0.1:${PRAXIS_PORT}"
    filter_chains: [codex-e2e]

filter_chains:
  - name: codex-e2e
    filters:
      - filter: openai_responses_format
        on_invalid: continue
        headers:
          format: x-praxis-ai-format
          model: x-praxis-ai-model
          stream: x-praxis-ai-stream

      - filter: openai_responses_model_rewrite
        model_aliases:
          codex-demo-client-name: "llama-3.3-70b"
        headers:
          effective_model: x-praxis-ai-effective-model
          original_model: x-praxis-ai-original-model

      - filter: router
        routes:
          - path: "/v1/responses"
            headers:
              x-praxis-ai-format: "openai_responses"
            cluster: "codex-backend"
          - path_prefix: "/"
            cluster: "codex-backend"

      - filter: load_balancer
        clusters:
          - name: "codex-backend"
            endpoints:
              - "127.0.0.1:${CODEX_BACKEND_PORT}"
YAML

start_praxis codex-e2e "$CONFIG" "$PRAXIS_PORT"

# ---------------------------------------------------------------------------
# Run Codex
# ---------------------------------------------------------------------------

log_section "Running Codex through Praxis"

log "Credentials unset: OPENAI_API_KEY=${OPENAI_API_KEY:-(unset)} CODEX_API_KEY=${CODEX_API_KEY:-(unset)}"

# Note: --dangerously-bypass-approvals-and-sandbox is used because bwrap
# (bubblewrap) sandbox does not work in container/CI environments that lack
# CAP_NET_ADMIN for loopback setup. The Codex process still runs in a
# temporary workspace directory with ephemeral state.
env -u OPENAI_API_KEY -u CODEX_API_KEY \
  CODEX_HOME="$WORK/codex-home" \
  codex exec \
    --ephemeral \
    --ignore-user-config \
    --skip-git-repo-check \
    --dangerously-bypass-approvals-and-sandbox \
    --json \
    -C "$WORK/workspace" \
    -c 'model="codex-demo-client-name"' \
    -c 'model_provider="praxis_e2e"' \
    -c 'model_providers.praxis_e2e.name="Praxis E2E"' \
    -c "model_providers.praxis_e2e.base_url=\"http://127.0.0.1:${PRAXIS_PORT}/v1\"" \
    -c 'model_providers.praxis_e2e.wire_api="responses"' \
    -c 'model_providers.praxis_e2e.request_max_retries=0' \
    -c 'model_providers.praxis_e2e.stream_max_retries=0' \
    'Create proof.txt containing exactly praxis-codex-e2e. Then report completion.' \
    </dev/null 2>"$LOG_DIR/codex-stderr.log" | tee "$WORK/codex.jsonl" || {
      log "Codex exited with non-zero status"
      log "stderr:"
      cat "$LOG_DIR/codex-stderr.log"
      exit 1
    }

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

log_section "Verifying results"

python3 "$SCRIPT_DIR/codex_e2e_verifier.py" \
  --log-dir "$LOG_DIR" \
  --codex-jsonl "$WORK/codex.jsonl" \
  --proof "$WORK/workspace/proof.txt" \
  --expected-model "llama-3.3-70b" \
  --expected-call-id "call_praxis_e2e_001" \
  --expected-proof-content "praxis-codex-e2e"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

log_section "Two-Request Transcript Summary"

echo "Request 1 (backend-visible):"
python3 -c "
import json
d = json.load(open('$LOG_DIR/backend-req-1.json'))
print(f'  model: {d.get(\"model\")}')
print(f'  stream: {d.get(\"stream\")}')
tools = [t.get('name') for t in d.get('tools', []) if isinstance(t, dict)]
print(f'  tools: {len(tools)} (includes exec_command={\"exec_command\" in tools})')
"

echo "Request 2 (backend-visible):"
python3 -c "
import json
d = json.load(open('$LOG_DIR/backend-req-2.json'))
print(f'  model: {d.get(\"model\")}')
fcos = [i for i in (d.get('input') or []) if isinstance(i, dict) and i.get('type') == 'function_call_output']
if fcos:
    print(f'  function_call_output.call_id: {fcos[0].get(\"call_id\")}')
    output = fcos[0].get('output', '')
    print(f'  function_call_output.output: {output[:100]}')
"

echo ""
echo "Proof: $(cat "$WORK/workspace/proof.txt" 2>/dev/null)"
echo "Codex version: $CODEX_VERSION"
echo "Praxis config: $CONFIG"

# Check no leftover processes
remaining=0
for pgid in "${PGIDS[@]:-}"; do
  if kill -0 "$pgid" 2>/dev/null; then
    remaining=$((remaining + 1))
  fi
done
log "Leftover processes: $remaining"

log "Codex E2E test passed."
