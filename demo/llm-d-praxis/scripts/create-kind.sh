#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Create a KIND cluster for the llm-d Praxis demo.
# Idempotent: skips creation if the cluster already exists.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

log_section "Creating KIND cluster: $KIND_CLUSTER_NAME"

if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
  log "KIND cluster $KIND_CLUSTER_NAME already exists. Skipping creation."
  kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}"
  exit 0
fi

# Bump inotify limits if they are too low (common on CI/dev hosts).
CURRENT_INSTANCES="$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)"
if [[ "$CURRENT_INSTANCES" -lt 256 ]]; then
  log "inotify max_user_instances is $CURRENT_INSTANCES (too low). Attempting to raise to 512."
  sudo sysctl -w fs.inotify.max_user_instances=512 2>/dev/null || \
    log "WARNING: Could not raise inotify limit. KIND may fail."
fi

cat <<EOF | kind create cluster --name "$KIND_CLUSTER_NAME" --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: ${PRAXIS_NODE_PORT}
    hostPort: ${PRAXIS_NODE_PORT}
    protocol: TCP
EOF

kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}"
kubectl get nodes

log "KIND cluster $KIND_CLUSTER_NAME created."
