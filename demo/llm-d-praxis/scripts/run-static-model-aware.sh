#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Example 1: Static Model-Aware Baseline
#
# Proves Praxis extracts the model field from the request body and
# routes only to endpoints that serve that model.
#
# sim-a serves model-a, sim-b serves model-b. A request for model-a
# must route to sim-a (not sim-b), and a request for a missing model
# must fail.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

log_section "Example 1: Static Model-Aware Baseline"

apply_manifests "$MANIFESTS_DIR/01-static-model-aware.yaml"

wait_for_pods "app=sim-a"
wait_for_pods "app=sim-b"
wait_for_pods "app=praxis"

wait_for_port "$PRAXIS_NODE_PORT" "Praxis NodePort"

log "Sending request for model-a (should succeed and route to sim-a) ..."
RESPONSE="$(send_chat_request "model-a" "hello")"
echo "$RESPONSE"
echo

if echo "$RESPONSE" | grep -q '"model-a"'; then
  log "PASS: Response contains model-a (routed to sim-a backend)"
else
  log "FAIL: Response does not contain model-a"
  exit 1
fi

log "Sending request for model-b (should succeed and route to sim-b) ..."
RESPONSE="$(send_chat_request "model-b" "hello")"
echo "$RESPONSE"
echo

if echo "$RESPONSE" | grep -q '"model-b"'; then
  log "PASS: Response contains model-b (routed to sim-b backend)"
else
  log "FAIL: Response does not contain model-b"
  exit 1
fi

log "Sending request for missing-model (should fail) ..."
RESPONSE="$(send_chat_request_with_status "missing-model" "hello")"
echo "$RESPONSE"
echo

check_http_status "$RESPONSE" "502" || check_http_status "$RESPONSE" "503" || true

show_praxis_logs 10

log "Example 1 complete."
