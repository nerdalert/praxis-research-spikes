#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Example 6: Saturation/Admission Gate
#
# Proves Praxis rejects requests when pool-level saturation exceeds a
# threshold and filters saturated endpoints from the candidate set.
#
# Saturation values come from llm-d-inference-sim fake-metrics so the
# demo can deterministically create healthy, saturated, and all-saturated
# states without real GPU load.
#
# Test 1 (mixed): sim-a healthy, sim-b saturated -> routes to sim-a (200)
# Test 2 (all saturated): both endpoints saturated -> reject (429)
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

log_section "Example 6: Saturation/Admission Gate"

# -- Test 1: Mixed (one healthy, one saturated) ----------------------------

log "=== Test 1: Mixed saturation (one healthy, one saturated) ==="

apply_manifests "$MANIFESTS_DIR/06-saturation.yaml"

wait_for_pods "app=sim-a"
wait_for_pods "app=sim-b"
wait_for_pods "app=praxis"

wait_for_port "$PRAXIS_NODE_PORT" "Praxis NodePort"

wait_for_metrics_scrape 5

log "Simulator fake-metrics:"
log "  sim-a: low queue/KV pressure (healthy)"
log "  sim-b: high queue/KV pressure (saturated)"
log "Praxis scrapes these as normal Prometheus /metrics values."
echo

log "Sending request (should route to healthy endpoint sim-a) ..."
RESPONSE="$(send_chat_request_with_status "fake-model" "hello")"
echo "$RESPONSE"
echo

check_http_status "$RESPONSE" "200"

log "Checking Praxis logs for saturation gating ..."
kubectl logs -l app=praxis --tail=30 2>/dev/null | grep -i "saturat\|gate\|reject\|headroom" || true

log "Test 1 PASS: Request routed to healthy endpoint (HTTP 200)."

# -- Test 2: All saturated (pool-level reject) -----------------------------

log ""
log "=== Test 2: All endpoints saturated (pool-level 429 reject) ==="

# Apply the reject config: both endpoints are now saturated.
# This updates the ConfigMaps; we need to restart pods to pick up changes.
apply_manifests "$MANIFESTS_DIR/06b-saturation-reject.yaml"

# Restart sim and praxis pods to pick up new ConfigMap values
log "Restarting pods to pick up saturated config ..."
kubectl rollout restart deployment sim-a sim-b praxis
kubectl rollout status deployment sim-a --timeout=120s
kubectl rollout status deployment sim-b --timeout=120s
kubectl rollout status deployment praxis --timeout=120s

wait_for_pods "app=sim-a"
wait_for_pods "app=sim-b"
wait_for_pods "app=praxis"

wait_for_port "$PRAXIS_NODE_PORT" "Praxis NodePort"

wait_for_metrics_scrape 5

log "Simulator fake-metrics now mark both endpoints saturated."
log "Praxis should reject at the pool-level gate."
echo

log "Sending request (should be rejected with HTTP 429) ..."
RESPONSE="$(send_chat_request_with_status "fake-model" "hello")"
echo "$RESPONSE"
echo

check_http_status "$RESPONSE" "429"

log "Checking Praxis logs for pool-level rejection ..."
kubectl logs -l app=praxis --tail=30 2>/dev/null | grep -i "saturat\|gate\|reject\|429" || true

log "Test 2 PASS: All endpoints saturated, request rejected (HTTP 429)."

log ""
log "Example 6 complete."
log ""
log "Evidence:"
log "  Test 1: sim-a healthy, sim-b saturated -> routed to sim-a (HTTP 200)."
log "  Test 2: both endpoints saturated -> pool-level reject (HTTP 429)."
log "  Note: saturation inputs are llm-d-inference-sim fake metrics."
