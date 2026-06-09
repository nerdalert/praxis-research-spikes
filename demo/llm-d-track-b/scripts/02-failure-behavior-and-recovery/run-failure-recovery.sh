#!/usr/bin/env bash
# 02 - Failure Behavior and Recovery
#
# Proves:
#   - Oversized request bodies are rejected before calling the EPP
#   - Praxis recovers when the EPP comes back after a failure
#
# Setup:
#   git clone -b track-b-benchmarking https://github.com/nerdalert/praxis.git praxis-track-b
#   cd praxis-track-b && cargo build --release -p praxis --features ext-proc
#   export TRACK_B_DIR="$(pwd)"
#   export EPP_BIN=/path/to/llm-d-router/bin/epp
#   export SIM_BIN=/path/to/llm-d-inference-sim/bin/llm-d-inference-sim
#
# Usage:
#   bash scripts/02-failure-behavior-and-recovery/run-failure-recovery.sh
#
# Manual curl equivalent (oversize):
#   dd if=/dev/zero bs=1048576 count=5 of=/tmp/oversize.bin
#   curl -s -w '\n%{http_code}' -X POST http://127.0.0.1:18091/v1/chat/completions \
#     -H "Content-Type: application/octet-stream" --data-binary @/tmp/oversize.bin

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

# ═══════════════════════════════════════════════════════════════════
header "02 - Failure Behavior and Recovery"
say "This proves body limits are enforced before the EPP is called,"
say "and that Praxis recovers after an EPP restart."
break_line

# ═══════════════════════════════════════════════════════════════════
header "Step 1: Start components"
start_simulator "test-model"
start_epp
start_praxis
break_line

# ═══════════════════════════════════════════════════════════════════
header "Step 2: Verify normal request works"
response=$(send_chat_request_with_status "test-model")
check_http_status "$response" "200" "normal request"
break_line

# ═══════════════════════════════════════════════════════════════════
header "Step 3: Send an oversized request (5 MiB > 4 MiB limit)"
say "The filter config sets max_request_body_bytes: 4194304 (4 MiB)."
say "Praxis should reject this with 413 without ever calling the Go EPP."
break_line

oversize_file=$(mktemp)
python3 -c "
import json, sys
padding = 'x' * (5 * 1024 * 1024)
obj = {'model': 'test-model', 'messages': [{'role': 'user', 'content': padding}]}
json.dump(obj, open('$oversize_file', 'w'))
"
say "Built ${oversize_file} ($(wc -c < "$oversize_file") bytes)"

oversize_status=$(curl -s -w "%{http_code}" -o /dev/null \
  -X POST "http://127.0.0.1:${PRAXIS_PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  --data-binary "@${oversize_file}")

if [[ "$oversize_status" == "413" ]]; then
  pass "oversized body -> HTTP 413 (rejected before EPP call)"
else
  fail "oversized body -> HTTP $oversize_status (expected 413)"
fi
rm -f "$oversize_file"
break_line

# ═══════════════════════════════════════════════════════════════════
header "Step 4: Stop the EPP and show fail-closed"
say "Stopping Go EPP..."
kill "$EPP_PID" 2>/dev/null || true
wait "$EPP_PID" 2>/dev/null || true
EPP_PID=""
sleep 1

fail_response=$(send_chat_request_with_status "test-model" "should fail")
check_http_status "$fail_response" "503" "request with EPP down"
break_line

# ═══════════════════════════════════════════════════════════════════
header "Step 5: Restart the EPP and show recovery"
say "Restarting Go EPP..."
start_epp
sleep 1

recovery_response=$(send_chat_request_with_status "test-model" "recovery test")
check_http_status "$recovery_response" "200" "request after EPP recovery"
break_line

show_epp_request_log
break_line

# ═══════════════════════════════════════════════════════════════════
header "What this demo proved:"
say "  - Oversized bodies (> max_request_body_bytes) return 413 before calling EPP"
say "  - EPP unavailability returns configured status_on_error (503)"
say "  - Praxis automatically reconnects to EPP after restart (lazy tonic channel)"
say "  - The recovery request goes through the new EPP process"
break_line

header "02 complete"
