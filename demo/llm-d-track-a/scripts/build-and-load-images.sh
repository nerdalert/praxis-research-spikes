#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build and load Praxis + llm-d-inference-sim images into KIND.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

log_section "Building and loading images"

# -- Build Praxis -----------------------------------------------------------

log "Building Praxis container image: $PRAXIS_IMAGE"

PRAXIS_IMAGE_NAME="${PRAXIS_IMAGE%%:*}"
PRAXIS_IMAGE_TAG="${PRAXIS_IMAGE##*:}"

(cd "$PRAXIS_DIR" && IMAGE="$PRAXIS_IMAGE_NAME" VERSION="$PRAXIS_IMAGE_TAG" make container)

# Handle podman -> docker transfer if needed.
if command -v podman >/dev/null 2>&1 && ! docker image inspect "$PRAXIS_IMAGE" >/dev/null 2>&1; then
  log "Transferring Praxis image from podman to docker ..."
  podman save "$PRAXIS_IMAGE" | docker load
fi

log "Loading Praxis image into KIND ..."
kind load docker-image "$PRAXIS_IMAGE" --name "$KIND_CLUSTER_NAME"

# -- Build llm-d-inference-sim ----------------------------------------------

log "Building llm-d-inference-sim image: $SIM_IMAGE"

(cd "$LLM_D_INFERENCE_SIM_DIR" && make image-build)

# Handle podman -> docker transfer if needed.
if command -v podman >/dev/null 2>&1 && ! docker image inspect "$SIM_IMAGE" >/dev/null 2>&1; then
  log "Transferring sim image from podman to docker ..."
  podman save "$SIM_IMAGE" | docker load
fi

log "Loading sim image into KIND ..."
kind load docker-image "$SIM_IMAGE" --name "$KIND_CLUSTER_NAME"

log "Images built and loaded."
