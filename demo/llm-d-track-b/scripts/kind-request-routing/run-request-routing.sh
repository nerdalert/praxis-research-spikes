#!/usr/bin/env bash
# E2E-V2-02 KIND request-routing suite
# Deploys generic ext_proc + endpoint_selector composition in KIND
# with unchanged Go EPP and inference simulator.
#
# Run from the praxis-research-spikes repository:
#   bash demo/llm-d-track-b/scripts/kind-request-routing/run-request-routing.sh
#
# Environment:
#   TRACK_B_DIR=...          Override the Track B workspace root.
#   PRAXIS_DIR=...           Override the full-duplex Praxis worktree.
#   LLM_D_ROUTER_REPO=...    Override the llm-d-router checkout.
#   LLM_D_SIM_REPO=...       Override the llm-d-inference-sim checkout.
#   SKIP_BUILD=1             Skip image builds.
#   SKIP_CLUSTER=1           Skip cluster creation (use existing).
#   KEEP_CLUSTER=1           Do not delete cluster on exit.
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="$(cd "${HARNESS_DIR}/.." && pwd)"
TRACK_B_DIR="${TRACK_B_DIR:-$(cd "${DEMO_DIR}/../../../.." && pwd)}"
PRAXIS_DIR="${PRAXIS_DIR:-${TRACK_B_DIR}/brent-ext-proc/praxis}"
EPP_DIR="${LLM_D_ROUTER_REPO:-${TRACK_B_DIR}/repos/llm-d-router}"
SIM_DIR="${LLM_D_SIM_REPO:-${TRACK_B_DIR}/../llm-d-benchmarks/repos/llm-d-inference-sim}"
LOG_DIR="${HARNESS_DIR}/logs"

CLUSTER_NAME="llmd-track-b-v2"
NAMESPACE="llmd-track-b-v2"
PRAXIS_IMAGE="praxis-track-b-v2:local"
EPP_IMAGE="go-epp-track-b-v2:local"
SIM_IMAGE="llmd-sim-track-b-v2:local"
NODE_PORT=30093
V2_MODEL="track-b-v2-model"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

cleanup() {
    local exit_status=$?
    echo "--- cleanup ---"
    if [[ "${KEEP_CLUSTER:-}" != "1" ]]; then
        kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
        echo "cluster deleted"
    else
        echo "KEEP_CLUSTER=1 — cluster preserved"
    fi
    exit "$exit_status"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

echo "=== preflight ==="
for cmd in kind kubectl docker; do
    command -v "$cmd" >/dev/null || { echo "FAIL: ${cmd} not found"; exit 1; }
done
echo "tools: kind=$(kind version 2>/dev/null | head -1), kubectl=$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"

mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------------
# Build images
# ---------------------------------------------------------------------------

if [[ "${SKIP_BUILD:-}" != "1" ]]; then
    echo ""
    echo "=== building Praxis v2 image ==="
    docker build -t "$PRAXIS_IMAGE" -f "${HARNESS_DIR}/Containerfile.praxis-track-b-v2" "$PRAXIS_DIR" 2>&1 | tail -5

    echo "=== building Go EPP image ==="
    docker build -t "$EPP_IMAGE" -f "${EPP_DIR}/Dockerfile.epp" "$EPP_DIR" 2>&1 | tail -5

    echo "=== building simulator image ==="
    docker build -t "$SIM_IMAGE" -f "${SIM_DIR}/Dockerfile" "$SIM_DIR" 2>&1 | tail -5
else
    echo "=== SKIP_BUILD=1 — using existing images ==="
fi

for img in "$PRAXIS_IMAGE" "$EPP_IMAGE" "$SIM_IMAGE"; do
    docker image inspect "$img" >/dev/null 2>&1 || { echo "FAIL: image ${img} not found"; exit 1; }
done
echo "all images present"

# ---------------------------------------------------------------------------
# Create cluster
# ---------------------------------------------------------------------------

if [[ "${SKIP_CLUSTER:-}" != "1" ]]; then
    echo ""
    echo "=== creating KIND cluster ${CLUSTER_NAME} ==="
    kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
    kind create cluster --name "$CLUSTER_NAME" --config "${HARNESS_DIR}/kind-config.yaml" 2>&1 | tail -3
else
    echo "=== SKIP_CLUSTER=1 — using existing cluster ==="
fi

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

echo "=== loading images into KIND ==="
kind load docker-image "$PRAXIS_IMAGE" --name "$CLUSTER_NAME" 2>&1 | tail -1
kind load docker-image "$EPP_IMAGE" --name "$CLUSTER_NAME" 2>&1 | tail -1
kind load docker-image "$SIM_IMAGE" --name "$CLUSTER_NAME" 2>&1 | tail -1

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------

echo ""
echo "=== deploying to namespace ${NAMESPACE} ==="
kubectl apply -f "${HARNESS_DIR}/manifests/namespace.yaml"

SIM_MANIFEST="${HARNESS_DIR}/manifests/simulator.yaml"
kubectl apply -f "$SIM_MANIFEST"

echo "waiting for simulator..."
kubectl -n "$NAMESPACE" rollout status deployment/simulator --timeout=60s

SIM_IP=$(kubectl -n "$NAMESPACE" get service simulator -o jsonpath='{.spec.clusterIP}')
echo "simulator ClusterIP: ${SIM_IP}"

EPP_MANIFEST="${LOG_DIR}/go-epp-resolved.yaml"
sed "s/EPP_SIM_ADDRESS/${SIM_IP}/g" "${HARNESS_DIR}/manifests/go-epp.yaml" > "$EPP_MANIFEST"
kubectl apply -f "$EPP_MANIFEST"

echo "waiting for Go EPP..."
kubectl -n "$NAMESPACE" rollout status deployment/go-epp --timeout=60s

kubectl apply -f "${HARNESS_DIR}/manifests/praxis.yaml"

echo "waiting for Praxis..."
kubectl -n "$NAMESPACE" rollout status deployment/praxis --timeout=60s

echo "all deployments ready"

# ---------------------------------------------------------------------------
# Test 1: Normal request routing
# ---------------------------------------------------------------------------

PRAXIS_URL="http://127.0.0.1:${NODE_PORT}"

echo ""
echo "=== test 1: normal request routing (model=${V2_MODEL}) ==="
RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 15 \
    -X POST -H "Content-Type: application/json" \
    "${PRAXIS_URL}/v1/chat/completions" \
    -d "{\"model\":\"${V2_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":5}" 2>&1)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)
echo "HTTP status: ${HTTP_CODE}"

if [[ "$HTTP_CODE" != "200" ]]; then
    echo "FAIL: expected 200, got ${HTTP_CODE}"
    kubectl -n "$NAMESPACE" logs deployment/praxis --tail=20 2>/dev/null || true
    kubectl -n "$NAMESPACE" logs deployment/go-epp --tail=20 2>/dev/null || true
    exit 1
fi

if ! echo "$BODY" | grep -q "$V2_MODEL"; then
    echo "FAIL: response does not contain model '${V2_MODEL}'"
    exit 1
fi
echo "PASS: correct model in response"

# ---------------------------------------------------------------------------
# Test 2: Repeated requests
# ---------------------------------------------------------------------------

echo ""
echo "=== test 2: repeated requests ==="
for i in 1 2 3; do
    R=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
        -X POST -H "Content-Type: application/json" \
        "${PRAXIS_URL}/v1/chat/completions" \
        -d "{\"model\":\"${V2_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"repeat ${i}\"}],\"max_tokens\":5}" 2>&1)
    if [[ "$R" != "200" ]]; then
        echo "FAIL: request ${i} returned ${R}"
        exit 1
    fi
    echo "  request ${i}: 200 OK"
done
echo "PASS: 3 repeated requests succeeded"

# ---------------------------------------------------------------------------
# Test 3: EPP failure and recovery
# ---------------------------------------------------------------------------

echo ""
echo "=== test 3: EPP failure -> 503 -> recovery ==="
kubectl -n "$NAMESPACE" scale deployment/go-epp --replicas=0 2>/dev/null
kubectl -n "$NAMESPACE" rollout status deployment/go-epp --timeout=30s 2>/dev/null || true
sleep 3

FAIL_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
    -X POST -H "Content-Type: application/json" \
    "${PRAXIS_URL}/v1/chat/completions" \
    -d "{\"model\":\"${V2_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"fail\"}]}" 2>&1)
echo "HTTP status with EPP down: ${FAIL_CODE}"

if [[ "$FAIL_CODE" != "503" ]]; then
    echo "FAIL: expected 503, got ${FAIL_CODE}"
    exit 1
fi
echo "PASS: EPP unavailable returns 503"

kubectl -n "$NAMESPACE" scale deployment/go-epp --replicas=1 2>/dev/null
echo "waiting for EPP recovery..."
kubectl -n "$NAMESPACE" rollout status deployment/go-epp --timeout=60s

sleep 3
RECOVERY_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
    -X POST -H "Content-Type: application/json" \
    "${PRAXIS_URL}/v1/chat/completions" \
    -d "{\"model\":\"${V2_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"recovered\"}],\"max_tokens\":5}" 2>&1)
echo "HTTP status after recovery: ${RECOVERY_CODE}"

if [[ "$RECOVERY_CODE" != "200" ]]; then
    echo "FAIL: expected 200 after recovery, got ${RECOVERY_CODE}"
    exit 1
fi
echo "PASS: EPP failure and recovery"

# ---------------------------------------------------------------------------
# Test 4: No h2 resets or GOAWAY errors
# ---------------------------------------------------------------------------

echo ""
echo "=== test 4: no unexpected h2 errors ==="
PRAXIS_LOGS=$(kubectl -n "$NAMESPACE" logs deployment/praxis 2>/dev/null || echo "")
RESET_COUNT=$(echo "$PRAXIS_LOGS" | grep -ci "h2.*reset\|GOAWAY\|stream reset" || true)
RESET_COUNT="${RESET_COUNT:-0}"
echo "h2 reset/GOAWAY mentions in Praxis logs: ${RESET_COUNT}"
if [[ "$RESET_COUNT" -gt 0 ]]; then
    echo "FAIL: found h2 reset/GOAWAY mentions"
    echo "$PRAXIS_LOGS" | grep -i "h2.*reset\|GOAWAY\|stream reset" || true
    exit 1
fi
echo "PASS: no unexpected h2 errors (${RESET_COUNT} mentions)"

# ---------------------------------------------------------------------------
# Test 5: Image identity
# ---------------------------------------------------------------------------

echo ""
echo "=== test 5: image identity ==="
DEPLOYED_IMAGE=$(kubectl -n "$NAMESPACE" get deployment praxis -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "deployed image: ${DEPLOYED_IMAGE}"
if [[ "$DEPLOYED_IMAGE" != "$PRAXIS_IMAGE" ]]; then
    echo "FAIL: expected ${PRAXIS_IMAGE}, got ${DEPLOYED_IMAGE}"
    exit 1
fi
echo "PASS: correct image deployed"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "=== all KIND request-routing checks passed ==="
echo "cluster: ${CLUSTER_NAME}"
echo "namespace: ${NAMESPACE}"
echo "model: ${V2_MODEL}"
echo "composition: ext_proc (full_duplex_streamed) + endpoint_selector (required, 503)"
