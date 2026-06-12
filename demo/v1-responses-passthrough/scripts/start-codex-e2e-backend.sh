#!/usr/bin/env bash
# Start the mock backend and Praxis for manual Codex E2E validation.
# Run this, then paste the codex command from the output.
# When done: ./scripts/stop-codex-e2e-backend.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PRAXIS_DIR="${PRAXIS_DIR:-$(cd "$DEMO_DIR/../../../praxis" && pwd)}"

PRAXIS_PORT="${PRAXIS_PORT:-18280}"
CODEX_BACKEND_PORT="${CODEX_BACKEND_PORT:-18285}"

WORK="$HOME/codex-e2e-manual"
rm -rf "$WORK"
mkdir -p "$WORK/logs" "$WORK/workspace" "$WORK/codex-home"

# Kill any leftover processes
pkill -f "codex-tool-loop-mock.*${CODEX_BACKEND_PORT}" 2>/dev/null || true
pkill -f "praxis.*${PRAXIS_PORT}" 2>/dev/null || true
sleep 0.5

# Start mock
LOG_DIR="$WORK/logs" python3 "$DEMO_DIR/mock-scripts/codex-tool-loop-mock.py" \
  --port "$CODEX_BACKEND_PORT" --name codex-backend \
  >"$WORK/logs/mock.log" 2>&1 &
MOCK_PID=$!
echo "$MOCK_PID" > "$WORK/mock.pid"
sleep 1

# Write config
cat > "$WORK/praxis.yaml" << YAML
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

# Start Praxis
RUST_LOG="${RUST_LOG:-praxis=info}" "$PRAXIS_DIR/target/debug/praxis" \
  -c "$WORK/praxis.yaml" \
  >"$WORK/logs/praxis.log" 2>&1 &
PRAXIS_PID=$!
echo "$PRAXIS_PID" > "$WORK/praxis.pid"
sleep 2

# Verify
MOCK_OK=false
PRAXIS_OK=false
(echo >"/dev/tcp/127.0.0.1/$CODEX_BACKEND_PORT") 2>/dev/null && MOCK_OK=true
(echo >"/dev/tcp/127.0.0.1/$PRAXIS_PORT") 2>/dev/null && PRAXIS_OK=true

echo ""
echo "=== Backend Status ==="
echo "  Mock backend: $MOCK_OK (pid=$MOCK_PID, port=$CODEX_BACKEND_PORT)"
echo "  Praxis:       $PRAXIS_OK (pid=$PRAXIS_PID, port=$PRAXIS_PORT)"
echo "  Workspace:    $WORK"
echo ""

if ! $MOCK_OK || ! $PRAXIS_OK; then
  echo "ERROR: services not ready" >&2
  cat "$WORK/logs/praxis.log" 2>/dev/null | tail -5
  exit 1
fi

echo "=== Paste this into Codex ==="
echo ""
cat << CMD
env -u OPENAI_API_KEY -u CODEX_API_KEY \\
  CODEX_HOME="$WORK/codex-home" \\
  codex exec \\
    --ephemeral \\
    --ignore-user-config \\
    --skip-git-repo-check \\
    --dangerously-bypass-approvals-and-sandbox \\
    --json \\
    -C "$WORK/workspace" \\
    -c 'model="codex-demo-client-name"' \\
    -c 'model_provider="praxis_e2e"' \\
    -c 'model_providers.praxis_e2e.name="Praxis E2E"' \\
    -c 'model_providers.praxis_e2e.base_url="http://127.0.0.1:${PRAXIS_PORT}/v1"' \\
    -c 'model_providers.praxis_e2e.wire_api="responses"' \\
    -c 'model_providers.praxis_e2e.request_max_retries=0' \\
    -c 'model_providers.praxis_e2e.stream_max_retries=0' \\
    'Create proof.txt containing exactly praxis-codex-e2e. Then report completion.' \\
    </dev/null
CMD
echo ""
echo "=== After Codex finishes, verify with ==="
echo ""
echo "cat $WORK/workspace/proof.txt"
echo "python3 $SCRIPT_DIR/codex_e2e_verifier.py \\"
echo "  --log-dir $WORK/logs \\"
echo "  --codex-jsonl /dev/stdin \\"
echo "  --proof $WORK/workspace/proof.txt \\"
echo "  --expected-model llama-3.3-70b \\"
echo "  --expected-call-id call_praxis_e2e_001 \\"
echo "  --expected-proof-content praxis-codex-e2e"
echo ""
echo "=== To clean up ==="
echo ""
echo "kill $MOCK_PID $PRAXIS_PID 2>/dev/null; rm -rf $WORK"
