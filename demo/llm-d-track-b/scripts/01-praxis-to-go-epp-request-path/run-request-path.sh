#!/usr/bin/env bash
# 01 - Praxis-to-Go-EPP Request Path
#
# Proves the complete request path:
#   Client -> Praxis -> Go EPP -> llm-d-inference-sim
#
# Setup:
#   git clone -b track-b-benchmarking https://github.com/nerdalert/praxis.git praxis-track-b
#   cd praxis-track-b && cargo build --release -p praxis --features ext-proc
#   export TRACK_B_DIR="$(pwd)"
#   export EPP_BIN=/path/to/llm-d-router/bin/epp
#   export SIM_BIN=/path/to/llm-d-inference-sim/bin/llm-d-inference-sim
#
# Usage:
#   bash scripts/01-praxis-to-go-epp-request-path/run-request-path.sh
#
# Manual curl equivalent:
#   curl -s -X POST http://127.0.0.1:18091/v1/chat/completions \
#     -H "Content-Type: application/json" \
#     -d '{"model":"test-model","messages":[{"role":"user","content":"hello"}],"max_tokens":10}'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

# ═══════════════════════════════════════════════════════════════════
header "01 - Praxis-to-Go-EPP Request Path"
say "Request path: Client -> Praxis -> Go EPP -> Simulator"
say "This proves Praxis can replace Envoy while keeping the Go EPP scheduler."
break_line

# ═══════════════════════════════════════════════════════════════════
header "Step 1: Start the components"
start_simulator "test-model"
start_epp
start_praxis
break_line

# ═══════════════════════════════════════════════════════════════════
header "Step 2: Send a request through Praxis -> Go EPP -> Simulator"
say "curl -s -X POST http://127.0.0.1:${PRAXIS_PORT}/v1/chat/completions \\"
say "  -H 'Content-Type: application/json' \\"
say "  -d '{\"model\":\"test-model\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":10}'"
break_line

response=$(send_chat_request_with_status "test-model" "hello from Track B demo")
check_http_status "$response" "200" "chat completion request"
break_line

say "Response body:"
echo "$response" | grep -v "HTTP_STATUS:" | python3 -m json.tool 2>/dev/null || echo "$response" | grep -v "HTTP_STATUS:"
break_line

# ═══════════════════════════════════════════════════════════════════
header "Step 3: Verify the Go EPP processed the request"
show_epp_request_log
break_line

# ═══════════════════════════════════════════════════════════════════
header "Step 4: Test fail-closed behavior (EPP unavailable)"
say "Stopping Go EPP..."
kill "$EPP_PID" 2>/dev/null || true
wait "$EPP_PID" 2>/dev/null || true
EPP_PID=""
sleep 1

say "curl -s -w '\\nHTTP_STATUS:%{http_code}\\n' http://127.0.0.1:${PRAXIS_PORT}/v1/chat/completions ..."
fail_response=$(send_chat_request_with_status "test-model" "should fail")
check_http_status "$fail_response" "503" "request with EPP down"
say "Praxis returned 503 (configured status_on_error) because the Go EPP is unavailable."
break_line

# ═══════════════════════════════════════════════════════════════════
header "What this demo proved:"
say "  - Praxis called the real Go EPP through ext_proc-compatible gRPC"
say "  - Go EPP selected the simulator endpoint (x-gateway-destination-endpoint)"
say "  - The request body reached the simulator without framing errors"
say "  - When the EPP is unavailable, Praxis returns the configured status_on_error (503)"
say "  - Praxis replaces Envoy in the request path; Go EPP remains the scheduler"
break_line

header "01 complete"
