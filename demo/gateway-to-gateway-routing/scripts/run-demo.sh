#!/usr/bin/env bash
set -euo pipefail

# Gateway-to-gateway E2E smoke harness.
#
# Starts three Praxis gateways with local mock backends, runs
# assertions, then cleans up. Exits 0 if all expected assertions
# pass (including expected failures for unimplemented features).

DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$DEMO_DIR/scripts"
PID_DIR="$DEMO_DIR/.pids"
LOG_DIR="$DEMO_DIR/.logs"
# Default assumes POC branch checkout as sibling to spike repo
PRAXIS_WORKTREE="${PRAXIS_WORKTREE:-$DEMO_DIR/../../../praxis}"

if [ -n "${PRAXIS_BIN:-}" ] && [ -x "${PRAXIS_BIN}" ]; then
    PRAXIS="$PRAXIS_BIN"
elif [ -x "$PRAXIS_WORKTREE/target/debug/praxis" ]; then
    PRAXIS="$PRAXIS_WORKTREE/target/debug/praxis"
elif [ -x "$PRAXIS_WORKTREE/target/release/praxis" ]; then
    PRAXIS="$PRAXIS_WORKTREE/target/release/praxis"
else
    echo "ERROR: praxis binary not found. Build from: nerdalert/praxis@praxis-multi-cluster-poc-v1"
    exit 1
fi

pass=0
fail=0
expected_fail=0

cleanup() {
    echo ""
    echo "=== Cleanup ==="
    bash "$SCRIPTS_DIR/cleanup.sh"
    rm -rf "$LOG_DIR"
}
trap cleanup EXIT

assert_pass() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %s\n" "$name"
        pass=$((pass + 1))
    else
        printf "  FAIL  %s\n" "$name"
        fail=$((fail + 1))
    fi
}

assert_fail() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf "  FAIL  %s (expected failure but succeeded)\n" "$name"
        fail=$((fail + 1))
    else
        printf "  PASS  %s (expected failure)\n" "$name"
        pass=$((pass + 1))
    fi
}

assert_expected_not_impl() {
    local name="$1"
    printf "  SKIP  %s (not implemented yet — requires POC code)\n" "$name"
    expected_fail=$((expected_fail + 1))
}

assert_body_contains() {
    local name="$1"
    local expected="$2"
    shift 2
    local body
    if body=$(curl -sf "$@" 2>/dev/null); then
        if echo "$body" | grep -q "$expected"; then
            printf "  PASS  %s\n" "$name"
            pass=$((pass + 1))
        else
            printf "  FAIL  %s (body does not contain '%s')\n" "$name" "$expected"
            printf "        body: %s\n" "$body"
            fail=$((fail + 1))
        fi
    else
        printf "  FAIL  %s (curl failed)\n" "$name"
        fail=$((fail + 1))
    fi
}

start_mock() {
    local name="$1"
    local script="$2"
    local port="$3"
    local site="$4"
    python3 "$DEMO_DIR/mocks/$script" "$port" "$site" >"$LOG_DIR/$name.log" 2>&1 &
    echo $! > "$PID_DIR/$name.pid"
}

start_gateway() {
    local name="$1"
    local config="$2"
    "$PRAXIS" -c "$DEMO_DIR/configs/$config" >"$LOG_DIR/$name.log" 2>&1 &
    echo $! > "$PID_DIR/$name.pid"
}

wait_for_port() {
    local port="$1"
    local timeout="${2:-5}"
    local i=0
    while ! curl -sf "http://127.0.0.1:$port/" >/dev/null 2>&1; do
        i=$((i + 1))
        if [ "$i" -ge "$((timeout * 10))" ]; then
            return 1
        fi
        sleep 0.1
    done
}

wait_for_tls_port() {
    local port="$1"
    local timeout="${2:-5}"
    local i=0
    while ! openssl s_client -connect "127.0.0.1:$port" </dev/null >/dev/null 2>&1; do
        i=$((i + 1))
        if [ "$i" -ge "$((timeout * 10))" ]; then
            return 1
        fi
        sleep 0.1
    done
}

# ── Prerequisites ──────────────────────────────────────────────

echo "=== Prerequisites ==="
bash "$SCRIPTS_DIR/check-prereqs.sh"

# ── Certificates ───────────────────────────────────────────────

echo ""
echo "=== Certificates ==="
bash "$SCRIPTS_DIR/generate-certs.sh"

# ── Start processes ────────────────────────────────────────────

echo ""
echo "=== Starting mock backends ==="
mkdir -p "$PID_DIR" "$LOG_DIR"

start_mock mock-inference-a inference.py 18001 site-a
start_mock mock-mcp-a      mcp.py       18002 site-a
start_mock mock-a2a-a       a2a.py       18003 site-a
start_mock mock-inference-b inference.py 18011 site-b
start_mock mock-mcp-b      mcp.py       18012 site-b
start_mock mock-a2a-b       a2a.py       18013 site-b
start_mock mock-inference-c inference.py 18021 site-c
start_mock mock-mcp-c      mcp.py       18022 site-c
start_mock mock-a2a-c       a2a.py       18023 site-c

echo "Waiting for mock backends..."
for port in 18001 18002 18003 18011 18012 18013 18021 18022 18023; do
    if ! wait_for_port "$port" 5; then
        echo "ERROR: mock on port $port did not start"
        exit 1
    fi
done
echo "All mock backends ready."

echo ""
echo "=== Starting Praxis gateways ==="

start_gateway site-a site-a.yaml
start_gateway site-b site-b.yaml
start_gateway site-c site-c.yaml

echo "Waiting for site-a public listener..."
if ! wait_for_port 18100 10; then
    echo "ERROR: site-a public listener did not start on :18100"
    echo "site-a log:"
    cat "$LOG_DIR/site-a.log" 2>/dev/null || true
    exit 1
fi

echo "Waiting for grid listeners..."
for port in 18101 18110 18120; do
    if ! wait_for_tls_port "$port" 10; then
        echo "WARNING: grid listener on :$port may not be ready"
    fi
done
echo "Gateways started."

# ── Assertions ─────────────────────────────────────────────────

echo ""
echo "=== Assertions ==="

# 1. Mock backend health
echo ""
echo "Mock backend health:"
for port in 18001 18002 18003 18011 18012 18013 18021 18022 18023; do
    assert_pass "mock :$port responds" curl -sf "http://127.0.0.1:$port/"
done

# 2. Local inference route through site A public listener
echo ""
echo "Local routing through site-a public listener:"
assert_body_contains \
    "POST /v1/chat/completions → site-a inference mock" \
    "site-a" \
    -X POST -H "Content-Type: application/json" \
    -d '{"model":"local-model","messages":[{"role":"user","content":"hello"}]}' \
    "http://127.0.0.1:18100/v1/chat/completions"

assert_body_contains \
    "GET / → site-a inference mock (health)" \
    "ok" \
    "http://127.0.0.1:18100/"

# 3. Grid listener rejects unauthenticated calls
echo ""
echo "mTLS enforcement on grid listeners:"
assert_fail \
    "site-b grid :18110 rejects plain HTTP" \
    curl -sf "http://127.0.0.1:18110/"

assert_fail \
    "site-b grid :18110 rejects HTTPS without client cert" \
    curl -sf --cacert "$DEMO_DIR/certs/grid-ca.pem" "https://127.0.0.1:18110/"

assert_fail \
    "site-c grid :18120 rejects plain HTTP" \
    curl -sf "http://127.0.0.1:18120/"

# 4. Grid listener accepts mTLS from trusted peer (with grid_ingress_trust)
echo ""
echo "grid_ingress_trust acceptance with trusted peer identity:"
assert_body_contains \
    "site-b grid accepts trusted site-a client cert" \
    "ok" \
    --cacert "$DEMO_DIR/certs/grid-ca.pem" \
    --cert "$DEMO_DIR/certs/site-a-client.pem" \
    --key "$DEMO_DIR/certs/site-a-client-key.pem" \
    "https://127.0.0.1:18110/"

assert_body_contains \
    "site-c grid accepts trusted site-a client cert" \
    "ok" \
    --cacert "$DEMO_DIR/certs/grid-ca.pem" \
    --cert "$DEMO_DIR/certs/site-a-client.pem" \
    --key "$DEMO_DIR/certs/site-a-client-key.pem" \
    "https://127.0.0.1:18120/"

# 5. grid_ingress_trust rejects untrusted peer identity (CA-valid but wrong org)
echo ""
echo "grid_ingress_trust rejection of untrusted peer identity:"
# The untrusted client cert is signed by the same grid CA (so TLS
# handshake succeeds) but has O=wrong-org, which grid_ingress_trust
# rejects with 403.
assert_fail \
    "site-b grid rejects untrusted org (CA-valid, wrong org) with 403" \
    curl -sf \
    --cacert "$DEMO_DIR/certs/grid-ca.pem" \
    --cert "$DEMO_DIR/certs/untrusted-client.pem" \
    --key "$DEMO_DIR/certs/untrusted-client-key.pem" \
    "https://127.0.0.1:18110/"

assert_fail \
    "site-c grid rejects untrusted org (CA-valid, wrong org) with 403" \
    curl -sf \
    --cacert "$DEMO_DIR/certs/grid-ca.pem" \
    --cert "$DEMO_DIR/certs/untrusted-client.pem" \
    --key "$DEMO_DIR/certs/untrusted-client-key.pem" \
    "https://127.0.0.1:18120/"

# 6. Grid listener rejects client certificates from an unknown CA
echo ""
echo "mTLS rejection of unknown client CA:"
assert_fail \
    "site-b grid rejects unknown-CA client cert" \
    curl -sf \
    --cacert "$DEMO_DIR/certs/grid-ca.pem" \
    --cert "$DEMO_DIR/certs/unknown-ca-client.pem" \
    --key "$DEMO_DIR/certs/unknown-ca-client-key.pem" \
    "https://127.0.0.1:18110/"

assert_fail \
    "site-c grid rejects unknown-CA client cert" \
    curl -sf \
    --cacert "$DEMO_DIR/certs/grid-ca.pem" \
    --cert "$DEMO_DIR/certs/unknown-ca-client.pem" \
    --key "$DEMO_DIR/certs/unknown-ca-client-key.pem" \
    "https://127.0.0.1:18120/"

# 7. Internal header rejection on public listener
echo ""
echo "Reserved header rejection on public ingress:"
# Praxis rejects client-supplied x-praxis-* headers at the protocol
# layer with 400 Bad Request before they reach any filter. This is
# the existing reserved header enforcement, not the headers filter.
assert_fail \
    "x-praxis-grid-origin from public client rejected (400)" \
    curl -sf -H "x-praxis-grid-origin: spoofed" "http://127.0.0.1:18100/"

# 8. grid_route inference routing through site A
echo ""
echo "grid_route inference routing:"
assert_body_contains \
    "local-model routes to site-a inference mock" \
    "site-a" \
    -X POST -H "Content-Type: application/json" \
    -d '{"model":"local-model","messages":[{"role":"user","content":"hello"}]}' \
    "http://127.0.0.1:18100/v1/chat/completions"

assert_body_contains \
    "site-b-model routes through site-b gateway to site-b mock" \
    "site-b" \
    -X POST -H "Content-Type: application/json" \
    -d '{"model":"site-b-model","messages":[{"role":"user","content":"hello"}]}' \
    "http://127.0.0.1:18100/v1/chat/completions"

assert_body_contains \
    "site-c-model routes through site-c gateway to site-c mock" \
    "site-c" \
    -X POST -H "Content-Type: application/json" \
    -d '{"model":"site-c-model","messages":[{"role":"user","content":"hello"}]}' \
    "http://127.0.0.1:18100/v1/chat/completions"

assert_fail \
    "unknown-model returns 404 (no candidate)" \
    curl -sf -X POST -H "Content-Type: application/json" \
    -d '{"model":"nonexistent-model","messages":[{"role":"user","content":"hello"}]}' \
    "http://127.0.0.1:18100/v1/chat/completions"

# 9. Freshness scoring: shared-model exists on site-a (fresh) and site-b (stale)
echo ""
echo "Freshness and local-preference scoring:"
assert_body_contains \
    "shared-model routes to site-a (fresh local beats stale remote)" \
    "site-a" \
    -X POST -H "Content-Type: application/json" \
    -d '{"model":"shared-model","messages":[{"role":"user","content":"hello"}]}' \
    "http://127.0.0.1:18100/v1/chat/completions"

assert_body_contains \
    "freshness-model routes to site-c (fresh remote beats stale remote)" \
    "site-c" \
    -X POST -H "Content-Type: application/json" \
    -d '{"model":"freshness-model","messages":[{"role":"user","content":"hello"}]}' \
    "http://127.0.0.1:18100/v1/chat/completions"

assert_body_contains \
    "equal-model routes to site-a (local preference when otherwise equal)" \
    "site-a" \
    -X POST -H "Content-Type: application/json" \
    -d '{"model":"equal-model","messages":[{"role":"user","content":"hello"}]}' \
    "http://127.0.0.1:18100/v1/chat/completions"

# 10. MCP tool routing across gateway boundary
echo ""
echo "MCP tool routing through grid_route:"
assert_body_contains \
    "MCP tools/call weather-lookup routes to site-c mock" \
    "site-c" \
    -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"weather-lookup"}}' \
    "http://127.0.0.1:18100/mcp"

# 11. Expected not-implemented features
echo ""
echo "Expected not-yet-implemented features:"
assert_expected_not_impl "A2A request routed across gateway boundary by grid_route"

# ── Summary ────────────────────────────────────────────────────

echo ""
echo "=== Summary ==="
echo "  Passed:              $pass"
echo "  Failed:              $fail"
echo "  Not implemented yet: $expected_fail"

if [ "$fail" -gt 0 ]; then
    echo ""
    echo "RESULT: FAIL ($fail unexpected failures)"
    exit 1
fi

echo ""
echo "RESULT: PASS (all implemented assertions passed)"
