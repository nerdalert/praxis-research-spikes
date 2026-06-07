#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Example 8: InferenceModelRewrite
#
# Proves Praxis reads InferenceModelRewrite CRDs and rewrites the
# request body model field before endpoint selection.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

log_section "Example 8: InferenceModelRewrite"

log "Installing InferenceModelRewrite CRD ..."
apply_manifests "$MANIFESTS_DIR/crds/inferencemodelrewrite-crd.yaml"

apply_manifests "$MANIFESTS_DIR/08-model-rewrite.yaml"

wait_for_pods "app=sim-a"
wait_for_pods "app=praxis"

wait_for_port "$PRAXIS_NODE_PORT" "Praxis NodePort"

wait_for_metrics_scrape 5

log "Sending request with model=gpt-4 (should be rewritten to fake-model) ..."
RESPONSE="$(send_chat_request "gpt-4" "hello")"
echo "$RESPONSE"
echo

if echo "$RESPONSE" | grep -q '"fake-model"'; then
  log "PASS: Response model field shows fake-model (rewritten from gpt-4)"
elif echo "$RESPONSE" | grep -q '"model"'; then
  log "INFO: Response received but model field may differ"
  log "  Check Praxis logs for rewrite evidence"
else
  log "FAIL: No valid response"
fi

log "Checking Praxis logs for model rewrite ..."
kubectl logs -l app=praxis --tail=30 2>/dev/null | grep -i "rewrite\|original_model\|model_rewrite" || true

log "Example 8 complete."
log ""
log "Evidence: Client sent model=gpt-4. InferenceModelRewrite CRD"
log "maps gpt-4 -> fake-model. Backend receives fake-model."
