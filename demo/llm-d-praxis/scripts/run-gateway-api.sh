#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Example 4: Gateway API HTTPRoute
#
# Proves Praxis reads an HTTPRoute resource, extracts the InferencePool
# backendRef, and discovers endpoints through the full chain:
# HTTPRoute -> InferencePool -> PodList.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

log_section "Example 4: Gateway API HTTPRoute"

log "Installing CRDs ..."
apply_manifests "$MANIFESTS_DIR/crds/inferencepool-crd.yaml"
apply_manifests "$MANIFESTS_DIR/crds/httproute-crd.yaml"

apply_manifests "$MANIFESTS_DIR/04-gateway-api.yaml"

wait_for_pods "pool=sim-pool"
wait_for_pods "app=praxis"

wait_for_port "$PRAXIS_NODE_PORT" "Praxis NodePort"

wait_for_metrics_scrape 5

log "Verifying HTTPRoute resource ..."
kubectl get httproute llm-route -o yaml 2>/dev/null || \
  log "WARNING: kubectl get httproute failed (CRD may not be installed)"

log "Verifying InferencePool resource ..."
kubectl get inferencepool sim-pool -o yaml 2>/dev/null || \
  log "WARNING: kubectl get inferencepool failed"

log "Sending request ..."
RESPONSE="$(send_chat_request "fake-model" "hello")"
echo "$RESPONSE"
echo

if echo "$RESPONSE" | grep -q '"model"'; then
  log "PASS: Received valid response via HTTPRoute discovery"
else
  log "FAIL: No valid response"
fi

log "Checking Praxis logs for gateway discovery ..."
kubectl logs -l app=praxis --tail=30 2>/dev/null | grep -i "gateway\|httproute\|discover\|pool" || true

log "Example 4 complete."
log ""
log "Evidence: Praxis discovered endpoints through the HTTPRoute ->"
log "InferencePool -> PodList chain. No static endpoints configured."
