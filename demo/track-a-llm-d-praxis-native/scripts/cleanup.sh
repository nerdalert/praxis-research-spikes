#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Clean up all demo resources and optionally delete the KIND cluster.
#
# Usage:
#   bash cleanup.sh          # Delete K8s resources, keep cluster
#   bash cleanup.sh --all    # Delete K8s resources AND the KIND cluster
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

log_section "Cleanup"

DELETE_CLUSTER=0
if [[ "${1:-}" == "--all" ]]; then
  DELETE_CLUSTER=1
fi

# Delete all demo resources (ignore errors for resources that don't exist).
log "Deleting demo K8s resources ..."

kubectl delete deployment praxis sim-a sim-b echo-a echo-b decode-backend prefill-backend --ignore-not-found 2>/dev/null || true
kubectl delete service praxis sim-a sim-b echo-a echo-b decode-backend prefill-backend --ignore-not-found 2>/dev/null || true
kubectl delete configmap praxis-config sim-a-config sim-b-config echo-a-config echo-b-config --ignore-not-found 2>/dev/null || true
kubectl delete serviceaccount praxis-sa --ignore-not-found 2>/dev/null || true
kubectl delete clusterrolebinding praxis-discovery --ignore-not-found 2>/dev/null || true
kubectl delete clusterrole praxis-discovery --ignore-not-found 2>/dev/null || true
kubectl delete inferencepool sim-pool --ignore-not-found 2>/dev/null || true
kubectl delete httproute llm-route --ignore-not-found 2>/dev/null || true
kubectl delete inferencemodelrewrite gpt4-rewrite --ignore-not-found 2>/dev/null || true
kubectl delete inferenceobjective high-priority --ignore-not-found 2>/dev/null || true

log "K8s resources deleted."

if [[ "$DELETE_CLUSTER" -eq 1 ]]; then
  log "Deleting KIND cluster: $KIND_CLUSTER_NAME ..."
  kind delete cluster --name "$KIND_CLUSTER_NAME"
  log "KIND cluster deleted."
else
  log "KIND cluster $KIND_CLUSTER_NAME preserved."
  log "  To delete: bash cleanup.sh --all"
  log "  Or: kind delete cluster --name $KIND_CLUSTER_NAME"
fi

log "Cleanup complete."
