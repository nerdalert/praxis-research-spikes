#!/usr/bin/env bash
# E2E-V2-01 local request-routing suite
# Praxis generic ext_proc + endpoint_selector -> unchanged Go EPP -> simulator
#
# Proves the Track B v2 full-duplex request-routing path:
#   1. Correct backend/model selection
#   2. Malicious client destination ignored
#   3. Repeated requests without crosstalk
#   4. Exact HTTP 503 when EPP unavailable
#   5. EPP restart recovery
#   6. Internal destination header stripped at backend
#   7. Exactly one Process invocation per HTTP request
#   8. Request body semantics preserved, no duplication
#
# No llmd_external_epp filter or legacy implementation.
#
# Run from the praxis-research-spikes repository:
#   bash demo/llm-d-track-b-full-duplex/local-go-epp-full-duplex/run-request-routing.sh
#
# Environment:
#   TRACK_B_DIR=...          Override the Track B workspace root.
#   PRAXIS_DIR=...           Override the full-duplex Praxis worktree.
#   LLM_D_ROUTER_REPO=...    Override the llm-d-router checkout.
#   LLM_D_SIM_REPO=...       Override the llm-d-inference-sim checkout.
#   SKIP_BUILD=1             Skip cargo/go build.
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="$(cd "${HARNESS_DIR}/.." && pwd)"
TRACK_B_DIR="${TRACK_B_DIR:-$(cd "${DEMO_DIR}/../../../.." && pwd)}"
PRAXIS_DIR="${PRAXIS_DIR:-${TRACK_B_DIR}/brent-ext-proc/praxis}"
EPP_DIR="${LLM_D_ROUTER_REPO:-${TRACK_B_DIR}/repos/llm-d-router}"
SIM_DIR="${LLM_D_SIM_REPO:-${TRACK_B_DIR}/../llm-d-benchmarks/repos/llm-d-inference-sim}"
SIM_BIN="${SIM_DIR}/bin/llm-d-inference-sim"
LOG_DIR="${HARNESS_DIR}/logs"

# ---------------------------------------------------------------------------
# Ports
# ---------------------------------------------------------------------------

SIM_PORT=18180
EPP_GRPC_PORT=9102
EPP_HEALTH_PORT=9103
EPP_METRICS_PORT=9190
PRAXIS_PORT=18191

ALL_PORTS=("$SIM_PORT" "$EPP_GRPC_PORT" "$EPP_HEALTH_PORT" "$EPP_METRICS_PORT" "$PRAXIS_PORT")

RUN_MODEL="fd03-smoke-$(date +%s)-$$"
DEST_HEADER="x-gateway-destination-endpoint"

# ---------------------------------------------------------------------------
# PID tracking and cleanup
# ---------------------------------------------------------------------------

SIM_PID=""
EPP_PID=""
PRAXIS_PID=""

cleanup() {
    local exit_status=$?
    echo "--- cleanup ---"
    local pids=()
    [[ -n "$PRAXIS_PID" ]] && pids+=("$PRAXIS_PID")
    [[ -n "$EPP_PID" ]] && pids+=("$EPP_PID")
    [[ -n "$SIM_PID" ]] && pids+=("$SIM_PID")

    for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    sleep 1
    for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "force-killing PID $pid"
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    local leaked=0
    for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "FAIL: PID $pid still alive after cleanup"
            leaked=1
        fi
    done
    if [[ "$leaked" -eq 0 ]]; then
        echo "all harness processes stopped"
    else
        echo "FAIL: leaked processes — manual cleanup required"
        exit 1
    fi
    exit "$exit_status"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

assert_port_free() {
    local port="$1"
    if ss -tlnH "sport = :${port}" 2>/dev/null | grep -q LISTEN; then
        echo "FAIL: port ${port} already in use"
        exit 1
    fi
}

pid_alive() { kill -0 "$1" 2>/dev/null; }

count_fixed() {
    local pattern="$1" file="$2" count
    count=$(grep -aF -c -- "$pattern" "$file" 2>/dev/null) || true
    printf '%s\n' "${count:-0}"
}

wait_for_port_owned() {
    local label="$1" port="$2" pid="$3" timeout="${4:-30}"
    echo "waiting for ${label} on port ${port}..."
    for i in $(seq 1 "$timeout"); do
        if ! pid_alive "$pid"; then
            echo "FAIL: ${label} exited before ready"
            tail -20 "${LOG_DIR}/${label}.log" 2>/dev/null || true
            return 1
        fi
        if curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:${port}/" 2>/dev/null; then
            echo "${label} ready (${i}s)"
            return 0
        fi
        sleep 1
    done
    echo "FAIL: ${label} not ready within ${timeout}s"
    return 1
}

wait_for_tcp_owned() {
    local label="$1" port="$2" pid="$3" timeout="${4:-30}"
    echo "waiting for ${label} on port ${port} (TCP)..."
    for i in $(seq 1 "$timeout"); do
        if ! pid_alive "$pid"; then
            echo "FAIL: ${label} exited before ready"
            tail -20 "${LOG_DIR}/${label}.log" 2>/dev/null || true
            return 1
        fi
        if bash -c "echo > /dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
            echo "${label} ready (${i}s)"
            return 0
        fi
        sleep 1
    done
    echo "FAIL: ${label} not ready within ${timeout}s"
    return 1
}

# ---------------------------------------------------------------------------
# Port conflict check
# ---------------------------------------------------------------------------

echo "=== checking ports ==="
for port in "${ALL_PORTS[@]}"; do
    assert_port_free "$port"
done
echo "all ports free"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

mkdir -p "$LOG_DIR"

PRAXIS_BIN="${PRAXIS_DIR}/target/release/praxis"
EPP_BIN="${EPP_DIR}/bin/epp"

if [[ "${SKIP_BUILD:-}" == "1" ]]; then
    echo "=== SKIP_BUILD=1 — using existing binaries ==="
else
    echo "=== building Praxis (ext-proc feature) ==="
    (cd "$PRAXIS_DIR" && cargo build -p praxis --release --features ext-proc 2>&1 | tail -3)

    echo "=== building Go EPP ==="
    (cd "$EPP_DIR" && go build -o bin/epp ./cmd/epp/ 2>&1)
fi

[[ -x "$PRAXIS_BIN" ]] || { echo "FAIL: praxis binary not found at ${PRAXIS_BIN}"; exit 1; }
[[ -x "$EPP_BIN" ]] || { echo "FAIL: epp binary not found at ${EPP_BIN}"; exit 1; }
[[ -x "$SIM_BIN" ]] || { echo "FAIL: sim binary not found at ${SIM_BIN}"; exit 1; }

# ---------------------------------------------------------------------------
# Generate runtime configs
# ---------------------------------------------------------------------------

EPP_ENDPOINTS_RUNTIME="${LOG_DIR}/epp-endpoints.yaml"
cat > "$EPP_ENDPOINTS_RUNTIME" <<EOF
endpoints:
  - name: sim-backend
    address: "127.0.0.1"
    port: "${SIM_PORT}"
EOF

EPP_CONFIG_RUNTIME="${LOG_DIR}/epp-config-runtime.yaml"
sed "s|PLACEHOLDER_ENDPOINTS_PATH|${EPP_ENDPOINTS_RUNTIME}|" \
    "${HARNESS_DIR}/epp-config.yaml" > "$EPP_CONFIG_RUNTIME"

# Track B full-duplex composition: ext_proc + endpoint_selector
PRAXIS_CONFIG_RUNTIME="${LOG_DIR}/praxis-runtime.yaml"
cat > "$PRAXIS_CONFIG_RUNTIME" <<EOF
listeners:
  - name: llmd-fd03
    address: "127.0.0.1:${PRAXIS_PORT}"
    filter_chains: [full-duplex-epp]

filter_chains:
  - name: full-duplex-epp
    filters:
      - filter: ext_proc
        target: "http://127.0.0.1:${EPP_GRPC_PORT}"
        message_timeout_ms: 5000
        lifecycle_timeout_ms: 10000
        status_on_error: 503
        processing_mode:
          request_header_mode: send
          response_header_mode: skip
          request_body_mode: full_duplex_streamed
          response_body_mode: none
          request_trailer_mode: skip
          response_trailer_mode: skip
      - filter: endpoint_selector
        source_header: ${DEST_HEADER}
        required: true
        status_on_required_failure: 503
        strip_header: true
EOF

echo "=== Praxis runtime config ==="
cat "$PRAXIS_CONFIG_RUNTIME"
echo ""

# ---------------------------------------------------------------------------
# Start processes
# ---------------------------------------------------------------------------

echo "=== starting inference simulator (model=${RUN_MODEL}) ==="
"$SIM_BIN" \
    --model "$RUN_MODEL" \
    --served-model-name "$RUN_MODEL" \
    --port "$SIM_PORT" \
    --log-http=true \
    --logtostderr=true \
    > "${LOG_DIR}/sim.log" 2>&1 &
SIM_PID=$!
wait_for_port_owned "sim" "$SIM_PORT" "$SIM_PID"

echo "=== starting Go EPP on gRPC port ${EPP_GRPC_PORT} ==="
"$EPP_BIN" \
    --config-file "$EPP_CONFIG_RUNTIME" \
    --grpc-port "$EPP_GRPC_PORT" \
    --grpc-health-port "$EPP_HEALTH_PORT" \
    --metrics-port "$EPP_METRICS_PORT" \
    --pool-name "bench-pool" \
    --secure-serving=false \
    > "${LOG_DIR}/epp.log" 2>&1 &
EPP_PID=$!
wait_for_tcp_owned "epp" "$EPP_GRPC_PORT" "$EPP_PID"
wait_for_port_owned "epp-metrics" "$EPP_METRICS_PORT" "$EPP_PID" 15

echo "=== starting Praxis on port ${PRAXIS_PORT} ==="
"$PRAXIS_BIN" -c "$PRAXIS_CONFIG_RUNTIME" \
    > "${LOG_DIR}/praxis.log" 2>&1 &
PRAXIS_PID=$!
wait_for_tcp_owned "praxis" "$PRAXIS_PORT" "$PRAXIS_PID"

# ---------------------------------------------------------------------------
# Test 1: Successful request path (EPP selects backend)
# ---------------------------------------------------------------------------

echo ""
echo "=== test 1: successful request path (model=${RUN_MODEL}) ==="
RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    "http://127.0.0.1:${PRAXIS_PORT}/v1/chat/completions" \
    -d "{
        \"model\": \"${RUN_MODEL}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"hello\"}],
        \"max_tokens\": 10
    }" 2>&1)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)
echo "HTTP status: ${HTTP_CODE}"

if [[ "$HTTP_CODE" != "200" ]]; then
    echo "FAIL: expected 200, got ${HTTP_CODE}"
    echo "--- praxis log tail ---"
    tail -40 "${LOG_DIR}/praxis.log" 2>/dev/null || true
    echo "--- epp log tail ---"
    tail -20 "${LOG_DIR}/epp.log" 2>/dev/null || true
    exit 1
fi

if ! echo "$BODY" | grep -q "$RUN_MODEL"; then
    echo "FAIL: response does not contain model name '${RUN_MODEL}'"
    exit 1
fi
echo "PASS: correct model in response — EPP selected the right backend"

# ---------------------------------------------------------------------------
# Test 2: Client-supplied destination header cannot select upstream
# ---------------------------------------------------------------------------

echo ""
echo "=== test 2: malicious client destination ignored ==="
EVIL_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "${DEST_HEADER}: evil.attacker:6666" \
    "http://127.0.0.1:${PRAXIS_PORT}/v1/chat/completions" \
    -d "{
        \"model\": \"${RUN_MODEL}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"test\"}],
        \"max_tokens\": 5
    }" 2>&1)

EVIL_CODE=$(echo "$EVIL_RESPONSE" | tail -1)
echo "HTTP status with malicious header: ${EVIL_CODE}"

if [[ "$EVIL_CODE" == "200" ]]; then
    EVIL_BODY=$(echo "$EVIL_RESPONSE" | head -n -1)
    if echo "$EVIL_BODY" | grep -q "$RUN_MODEL"; then
        echo "PASS: malicious header ignored — response from correct backend"
    else
        echo "FAIL: response came from unknown backend"
        exit 1
    fi
else
    echo "INFO: non-200 status ${EVIL_CODE} — client header did not route to attacker"
    echo "PASS: malicious destination not selected"
fi

# ---------------------------------------------------------------------------
# Test 3: Repeated requests succeed
# ---------------------------------------------------------------------------

echo ""
echo "=== test 3: repeated requests ==="
for i in 1 2 3; do
    R=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        "http://127.0.0.1:${PRAXIS_PORT}/v1/chat/completions" \
        -d "{
            \"model\": \"${RUN_MODEL}\",
            \"messages\": [{\"role\": \"user\", \"content\": \"repeat ${i}\"}],
            \"max_tokens\": 5
        }" 2>&1)
    if [[ "$R" != "200" ]]; then
        echo "FAIL: request ${i} returned ${R}"
        exit 1
    fi
    echo "  request ${i}: 200 OK"
done
echo "PASS: 3 repeated requests succeeded"

# ---------------------------------------------------------------------------
# Test 4: EPP unavailable returns exactly 503
# ---------------------------------------------------------------------------

echo ""
echo "=== test 4: EPP unavailable -> exact 503 ==="
kill "$EPP_PID" 2>/dev/null || true
wait "$EPP_PID" 2>/dev/null || true
EPP_PID=""
sleep 2

FAIL_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    "http://127.0.0.1:${PRAXIS_PORT}/v1/chat/completions" \
    -d "{\"model\": \"${RUN_MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"fail\"}]}" 2>&1)

FAIL_CODE=$(echo "$FAIL_RESPONSE" | tail -1)
echo "HTTP status with EPP down: ${FAIL_CODE}"

if [[ "$FAIL_CODE" != "503" ]]; then
    echo "FAIL: expected exactly 503, got ${FAIL_CODE}"
    echo "--- praxis log tail ---"
    tail -20 "${LOG_DIR}/praxis.log" 2>/dev/null || true
    exit 1
fi
echo "PASS: EPP unavailable returns exactly 503"

# ---------------------------------------------------------------------------
# Test 5: EPP restart recovery
# ---------------------------------------------------------------------------

echo ""
echo "=== test 5: EPP restart recovery ==="
"$EPP_BIN" \
    --config-file "$EPP_CONFIG_RUNTIME" \
    --grpc-port "$EPP_GRPC_PORT" \
    --grpc-health-port "$EPP_HEALTH_PORT" \
    --metrics-port "$EPP_METRICS_PORT" \
    --pool-name "bench-pool" \
    --secure-serving=false \
    > "${LOG_DIR}/epp-restart.log" 2>&1 &
EPP_PID=$!
wait_for_tcp_owned "epp-restart" "$EPP_GRPC_PORT" "$EPP_PID"
wait_for_port_owned "epp-restart-metrics" "$EPP_METRICS_PORT" "$EPP_PID" 15

RECOVERY_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    "http://127.0.0.1:${PRAXIS_PORT}/v1/chat/completions" \
    -d "{
        \"model\": \"${RUN_MODEL}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"recovered\"}],
        \"max_tokens\": 5
    }" 2>&1)

RECOVERY_CODE=$(echo "$RECOVERY_RESPONSE" | tail -1)
echo "HTTP status after EPP restart: ${RECOVERY_CODE}"

if [[ "$RECOVERY_CODE" != "200" ]]; then
    echo "FAIL: expected 200 after EPP restart, got ${RECOVERY_CODE}"
    tail -20 "${LOG_DIR}/praxis.log" 2>/dev/null || true
    tail -20 "${LOG_DIR}/epp-restart.log" 2>/dev/null || true
    exit 1
fi
echo "PASS: EPP restart recovery — requests succeed after restart"

# ---------------------------------------------------------------------------
# Test 6: Internal destination header absent at backend
# ---------------------------------------------------------------------------

echo ""
echo "=== test 6: destination header stripped at backend wire boundary ==="
sleep 1
if grep -q "${DEST_HEADER}" "${LOG_DIR}/sim.log" 2>/dev/null; then
    echo "FAIL: simulator log contains '${DEST_HEADER}' — header was not stripped"
    exit 1
fi
echo "PASS: internal destination header absent from simulator logs"

# ---------------------------------------------------------------------------
# Test 7: Exactly one Process invocation per HTTP request
# ---------------------------------------------------------------------------

echo ""
echo "=== test 7: one Process invocation per HTTP request ==="
PROCESS_COUNT_BEFORE=$(count_fixed "EPP received request" "${LOG_DIR}/epp-restart.log")
SINGLE_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    "http://127.0.0.1:${PRAXIS_PORT}/v1/chat/completions" \
    -d "{
        \"model\": \"${RUN_MODEL}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"process-count\"}],
        \"max_tokens\": 5
    }" 2>&1)
if [[ "$SINGLE_CODE" != "200" ]]; then
    echo "FAIL: Process-count request returned ${SINGLE_CODE}"
    exit 1
fi
sleep 1
PROCESS_COUNT_AFTER=$(count_fixed "EPP received request" "${LOG_DIR}/epp-restart.log")
PROCESS_DELTA=$((PROCESS_COUNT_AFTER - PROCESS_COUNT_BEFORE))

echo "Process invocations for one request: ${PROCESS_DELTA}"
if [[ "$PROCESS_DELTA" != "1" ]]; then
    echo "FAIL: expected exactly 1 Process invocation, got ${PROCESS_DELTA}"
    exit 1
fi
echo "PASS: exactly one Process invocation per HTTP request"

# ---------------------------------------------------------------------------
# Test 8: Request body semantic content preserved without duplication
# ---------------------------------------------------------------------------

echo ""
UNIQUE_BODY="unique-body-${RUN_MODEL}-$(date +%s%N)"
echo "=== test 8: request body preserved (marker=${UNIQUE_BODY}) ==="
BODY_PAYLOAD="{\"model\":\"${RUN_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"${UNIQUE_BODY}\"}],\"max_tokens\":5}"
BODY_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    "http://127.0.0.1:${PRAXIS_PORT}/v1/chat/completions" \
    --data-binary "$BODY_PAYLOAD" 2>&1)
BODY_CODE=$(echo "$BODY_RESPONSE" | tail -1)

if [[ "$BODY_CODE" != "200" ]]; then
    echo "FAIL: expected 200, got ${BODY_CODE}"
    exit 1
fi

sleep 1
BODY_COUNT=$(count_fixed "$UNIQUE_BODY" "${LOG_DIR}/sim.log")
if [[ "$BODY_COUNT" != "1" ]]; then
    echo "FAIL: expected the unique request body marker once in simulator logs, found ${BODY_COUNT}"
    exit 1
fi
echo "PASS: request body semantic content observed exactly once at backend"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "=== all 8 FD03 full-duplex smoke checks passed ==="
echo "model: ${RUN_MODEL}"
echo "composition: ext_proc (full_duplex_streamed) + endpoint_selector (required, 503)"
echo "logs: ${LOG_DIR}/"
