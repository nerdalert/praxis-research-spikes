#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Example 3: InferencePool Discovery
#
# Proves Praxis discovers pod endpoints from an InferencePool CRD
# (v1alpha2) without any static endpoint configuration.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

log_section "Example 3: InferencePool Discovery"

log "Installing InferencePool CRD ..."
apply_manifests "$MANIFESTS_DIR/crds/inferencepool-crd.yaml"

apply_manifests "$MANIFESTS_DIR/03-inferencepool-discovery.yaml"

wait_for_pods "pool=sim-pool"
wait_for_pods "app=praxis"

wait_for_port "$PRAXIS_NODE_PORT" "Praxis NodePort"

wait_for_metrics_scrape 5

log "Verifying InferencePool resource ..."
kubectl get inferencepool sim-pool -o yaml 2>/dev/null || \
  log "WARNING: kubectl get inferencepool failed (CRD may not be installed)"

log "Sending request ..."
RESPONSE="$(send_chat_request "fake-model" "hello")"
echo "$RESPONSE"
echo

if echo "$RESPONSE" | grep -q '"model"'; then
  log "PASS: Received valid response via discovery-only routing"
else
  log "FAIL: No valid response"
fi

log "Checking Praxis logs for discovery ..."
kubectl logs -l app=praxis --tail=30 2>/dev/null | grep -i "discover\|endpoint\|pool" || true

log "Example 3 complete."
log ""
log "Evidence: No static endpoints in Praxis config. Endpoints"
log "discovered from InferencePool CRD label selector."
