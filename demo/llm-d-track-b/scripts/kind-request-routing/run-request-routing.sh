#!/usr/bin/env bash
# KIND request-routing demo for the generic full-duplex ext_proc integration.
#
# Run from the praxis-research-spikes repository:
#   bash demo/llm-d-track-b/scripts/kind-request-routing/run-request-routing.sh
#
# Environment:
#   TRACK_B_DIR=...          Override the Track B experiment root.
#   PRAXIS_DIR=...           Required: Praxis source checkout to build.
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
PRAXIS_DIR="${PRAXIS_DIR:-}"
EPP_DIR="${LLM_D_ROUTER_REPO:-${TRACK_B_DIR}/repos/llm-d-router}"
SIM_DIR="${LLM_D_SIM_REPO:-${TRACK_B_DIR}/repos/llm-d-inference-sim}"
LOG_DIR="${HARNESS_DIR}/logs"

CLUSTER_NAME="llmd-track-b-v2"
NAMESPACE="llmd-track-b-v2"
PRAXIS_IMAGE="praxis-track-b-v2:local"
EPP_IMAGE="go-epp-track-b-v2:local"
SIM_IMAGE="llmd-sim-track-b-v2:local"
HEADER_ECHO_IMAGE="header-echo-track-b-v2:local"
NODE_PORT=30093
V2_MODEL="track-b-v2-model"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

require_directory() {
    local name="$1"
    local path="$2"
    if [[ ! -d "$path" ]]; then
        echo "FAIL: ${name} checkout is not available"
        echo "Set the corresponding override environment variable and retry."
        exit 1
    fi
}

request_status() {
    local body="$1"
    curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
        -X POST -H "Content-Type: application/json" \
        "${PRAXIS_URL}/v1/chat/completions" \
        -d "$body"
}

wait_for_status() {
    local expected="$1"
    local body="$2"
    local description="$3"
    local status
    for _ in $(seq 1 30); do
        status=$(request_status "$body" || true)
        if [[ "$status" == "$expected" ]]; then
            echo "HTTP status: ${status} (${description})"
            return
        fi
        sleep 1
    done
    echo "FAIL: expected HTTP ${expected} while ${description}; last status was ${status:-unavailable}"
    exit 1
}

configure_epp_backend() {
    local backend_ip="$1"
    local backend_port="$2"
    local backend_name="$3"
    local manifest="${LOG_DIR}/go-epp-${backend_name}.yaml"

    sed -e "s/EPP_BACKEND_ADDRESS/${backend_ip}/g" -e "s/EPP_BACKEND_PORT/${backend_port}/g" \
        "${HARNESS_DIR}/manifests/go-epp.yaml" > "$manifest"
    kubectl apply -f "$manifest" >/dev/null
    kubectl -n "$NAMESPACE" rollout restart deployment/go-epp >/dev/null
    kubectl -n "$NAMESPACE" rollout status deployment/go-epp --timeout=60s
    wait_for_status "200" "{\"model\":\"${V2_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"warmup\"}],\"max_tokens\":5}" "EPP ready with ${backend_name}"
    echo "Go EPP now selects the ${backend_name} backend"
}

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

echo "=== Praxis full-duplex ext_proc KIND demo ==="
echo ""
echo "This deploys the PR3 Praxis source with the generic ext_proc filter,"
echo "the unchanged Go EPP scheduler, and an inference simulator. Each HTTP"
echo "request keeps one bidirectional Process stream open while Praxis sends"
echo "headers, body data, and EOS before Go EPP returns the selected endpoint."
echo ""
echo "The demo validates request routing only. It does not claim response-phase"
echo "ext_proc processing, vLLM behavior, or Gateway API pool management."
echo ""
echo "=== preflight and source identity ==="
for cmd in kind kubectl docker curl sha256sum; do
    command -v "$cmd" >/dev/null || { echo "FAIL: ${cmd} not found"; exit 1; }
done
echo "tools: kind=$(kind version 2>/dev/null | head -1), kubectl=$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"

require_directory "Praxis" "$PRAXIS_DIR"
require_directory "Go EPP" "$EPP_DIR"
require_directory "inference simulator" "$SIM_DIR"

PRAXIS_BRANCH=$(git -C "$PRAXIS_DIR" branch --show-current)
PRAXIS_REVISION=$(git -C "$PRAXIS_DIR" rev-parse --short=12 HEAD)
if [[ -n "$(git -C "$PRAXIS_DIR" status --porcelain)" ]]; then
    PRAXIS_SOURCE_STATE="dirty"
else
    PRAXIS_SOURCE_STATE="clean"
fi
PRAXIS_SOURCE_ID="${PRAXIS_REVISION}-${PRAXIS_SOURCE_STATE}"
echo "Praxis source: branch=${PRAXIS_BRANCH}, revision=${PRAXIS_REVISION}, state=${PRAXIS_SOURCE_STATE}"
echo "Composition: ext_proc(request_body_mode=full_duplex_streamed) -> endpoint_selector(required, 503)"

mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------------
# Build images
# ---------------------------------------------------------------------------

if [[ "${SKIP_BUILD:-}" != "1" ]]; then
    echo ""
    echo "=== building images from the declared source checkouts ==="
    echo "Praxis image: compiling ${PRAXIS_SOURCE_ID} with the ext-proc feature enabled"
    docker build -t "$PRAXIS_IMAGE" -f "${HARNESS_DIR}/Containerfile.praxis-track-b-v2" \
        "$PRAXIS_DIR" 2>&1 | tail -5

    echo "Go EPP image: compiling the existing scheduler implementation"
    docker build -t "$EPP_IMAGE" -f "${EPP_DIR}/Dockerfile.epp" "$EPP_DIR" 2>&1 | tail -5

    echo "Simulator image: compiling the OpenAI-compatible inference backend"
    docker build -t "$SIM_IMAGE" -f "${SIM_DIR}/Dockerfile" "$SIM_DIR" 2>&1 | tail -5

    echo "Header-echo image: compiling the wire-observation backend used only for test 4"
    docker build -t "$HEADER_ECHO_IMAGE" -f "${HARNESS_DIR}/Containerfile.header-echo" "$HARNESS_DIR" 2>&1 | tail -5
else
    echo "=== SKIP_BUILD=1 — using existing images ==="
    echo "WARNING: image provenance cannot be tied to the current source checkout when builds are skipped."
fi

for img in "$PRAXIS_IMAGE" "$EPP_IMAGE" "$SIM_IMAGE" "$HEADER_ECHO_IMAGE"; do
    docker image inspect "$img" >/dev/null 2>&1 || { echo "FAIL: image ${img} not found"; exit 1; }
done
PRAXIS_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$PRAXIS_IMAGE")
echo "Praxis image identity: ${PRAXIS_IMAGE_ID}"
if [[ "${SKIP_BUILD:-}" != "1" ]]; then
    echo "Praxis image was built directly from ${PRAXIS_SOURCE_ID} in this run"
fi

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

echo "=== loading the exact local images into KIND ==="
kind load docker-image "$PRAXIS_IMAGE" --name "$CLUSTER_NAME" 2>&1 | tail -1
kind load docker-image "$EPP_IMAGE" --name "$CLUSTER_NAME" 2>&1 | tail -1
kind load docker-image "$SIM_IMAGE" --name "$CLUSTER_NAME" 2>&1 | tail -1
kind load docker-image "$HEADER_ECHO_IMAGE" --name "$CLUSTER_NAME" 2>&1 | tail -1

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------

echo ""
echo "=== deploying the request-routing composition to namespace ${NAMESPACE} ==="
kubectl apply -f "${HARNESS_DIR}/manifests/namespace.yaml"

SIM_MANIFEST="${HARNESS_DIR}/manifests/simulator.yaml"
kubectl apply -f "$SIM_MANIFEST"

echo "waiting for simulator..."
kubectl -n "$NAMESPACE" rollout status deployment/simulator --timeout=60s

kubectl apply -f "${HARNESS_DIR}/manifests/header-echo.yaml"
echo "waiting for header-echo backend..."
kubectl -n "$NAMESPACE" rollout status deployment/header-echo --timeout=60s

SIM_IP=$(kubectl -n "$NAMESPACE" get service simulator -o jsonpath='{.spec.clusterIP}')
HEADER_ECHO_IP=$(kubectl -n "$NAMESPACE" get service header-echo -o jsonpath='{.spec.clusterIP}')
echo "simulator backend ready"
echo "header-observation backend ready"

echo "waiting for Go EPP..."
EPP_MANIFEST="${LOG_DIR}/go-epp-simulator.yaml"
sed -e "s/EPP_BACKEND_ADDRESS/${SIM_IP}/g" -e 's/EPP_BACKEND_PORT/8000/g' \
    "${HARNESS_DIR}/manifests/go-epp.yaml" > "$EPP_MANIFEST"
kubectl apply -f "$EPP_MANIFEST" >/dev/null
kubectl -n "$NAMESPACE" rollout status deployment/go-epp --timeout=60s

kubectl apply -f "${HARNESS_DIR}/manifests/praxis.yaml"

echo "waiting for Praxis..."
kubectl -n "$NAMESPACE" rollout status deployment/praxis --timeout=60s

echo "all deployments ready: Praxis -> Go EPP -> simulator"
kubectl -n "$NAMESPACE" get pods -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,IMAGE:.spec.containers[0].image'

# ---------------------------------------------------------------------------
# Test 1: Normal request routing
# ---------------------------------------------------------------------------

PRAXIS_URL="http://127.0.0.1:${NODE_PORT}"

echo ""
echo "=== test 1: full-duplex routing through the real Go EPP ==="
echo "Send headers and a JSON body to Praxis. Go EPP waits for request EOS, selects"
echo "the simulator endpoint, and Praxis forwards the original request to that endpoint."
RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 15 \
    -X POST -H "Content-Type: application/json" \
    "${PRAXIS_URL}/v1/chat/completions" \
    -d "{\"model\":\"${V2_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":5}" 2>&1)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)
echo "HTTP status: ${HTTP_CODE}"

if [[ "$HTTP_CODE" != "200" ]]; then
    echo "FAIL: expected 200, got ${HTTP_CODE}"
    echo "response body: ${BODY}"
    kubectl -n "$NAMESPACE" logs deployment/praxis --tail=20 2>/dev/null || true
    kubectl -n "$NAMESPACE" logs deployment/go-epp --tail=20 2>/dev/null || true
    exit 1
fi
if ! echo "$BODY" | grep -q "$V2_MODEL"; then
    echo "FAIL: simulator response does not identify model '${V2_MODEL}'"
    echo "response body: ${BODY}"
    exit 1
fi
echo "PASS: HTTP 200 and simulator response identifies model '${V2_MODEL}'"

# ---------------------------------------------------------------------------
# Test 2: Repeated requests
# ---------------------------------------------------------------------------

echo ""
echo "=== test 2: repeated independent requests ==="
echo "Exercise the complete routing lifecycle three times in succession. The focused"
echo "Rust integration suite separately verifies one isolated Process stream per request;"
echo "this cluster check verifies that repeat traffic continues to route successfully."
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
echo "PASS: all 3 independent requests completed through the routing path"

# ---------------------------------------------------------------------------
# Test 3: Spoofed destination header rejected
# ---------------------------------------------------------------------------

echo ""
echo "=== test 3: spoofed destination header cannot select upstream ==="
echo "The client supplies an unreachable endpoint. A 200 from the configured simulator"
echo "means Praxis used the Go EPP's trusted endpoint mutation, not the client header."
SPOOF_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 15 \
    -X POST -H "Content-Type: application/json" \
    -H "x-gateway-destination-endpoint: 10.99.99.99:9999" \
    "${PRAXIS_URL}/v1/chat/completions" \
    -d "{\"model\":\"${V2_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"spoof\"}],\"max_tokens\":5}" 2>&1)
SPOOF_CODE=$(echo "$SPOOF_RESPONSE" | tail -1)
SPOOF_BODY=$(echo "$SPOOF_RESPONSE" | head -n -1)
echo "HTTP status with spoofed header: ${SPOOF_CODE}"

if [[ "$SPOOF_CODE" != "200" ]]; then
    echo "FAIL: expected 200 (spoofed header ignored, real EPP routes), got ${SPOOF_CODE}"
    exit 1
fi
if ! echo "$SPOOF_BODY" | grep -q "$V2_MODEL"; then
    echo "FAIL: spoofed request did not reach the configured simulator"
    exit 1
fi
echo "PASS: client destination was ignored; simulator response identifies model '${V2_MODEL}'"

# ---------------------------------------------------------------------------
# Test 4: Backend does not see internal destination header
# ---------------------------------------------------------------------------

echo ""
echo "=== test 4: backend header stripping and body integrity ==="
echo "Point the real Go EPP at the header-echo backend. The backend returns the"
echo "received headers and a SHA-256 of the request body, proving both that the"
echo "internal routing header is stripped and that a non-empty request body reaches"
echo "the selected backend. This check does not claim byte identity: Go EPP"
echo "re-serializes JSON before forwarding it."
configure_epp_backend "$HEADER_ECHO_IP" "8080" "header-echo"

STRIP_REQUEST='{"model":"track-b-v2-model","messages":[{"role":"user","content":"strip-check"}],"max_tokens":5}'
STRIP_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 15 \
    -X POST -H "Content-Type: application/json" \
    "${PRAXIS_URL}/v1/chat/completions" \
    -d "$STRIP_REQUEST" 2>&1)

STRIP_CODE=$(echo "$STRIP_RESPONSE" | tail -1)
STRIP_BODY=$(echo "$STRIP_RESPONSE" | head -n -1)
echo "HTTP status from header-echo backend: ${STRIP_CODE}"
if [[ "$STRIP_CODE" != "200" ]]; then
    echo "FAIL: header-echo backend returned ${STRIP_CODE}"
    echo "response body: ${STRIP_BODY}"
    kubectl -n "$NAMESPACE" logs deployment/header-echo --tail=10 2>/dev/null || true
    kubectl -n "$NAMESPACE" logs deployment/praxis --tail=10 2>/dev/null || true
    exit 1
fi

if echo "$STRIP_BODY" | grep -qi 'x-gateway-destination-endpoint'; then
    echo "FAIL: internal destination header reached the backend"
    echo "response: ${STRIP_BODY}"
    exit 1
fi
echo "PASS: x-gateway-destination-endpoint is absent from backend headers"

BODY_SHA=$(echo "$STRIP_BODY" | grep -oP '"body_sha256":"\K[0-9a-f]{64}')
EMPTY_SHA="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
if [[ -z "$BODY_SHA" ]]; then
    echo "FAIL: header-echo response does not contain body_sha256"
    exit 1
fi
if [[ "$BODY_SHA" == "$EMPTY_SHA" ]]; then
    echo "FAIL: backend received empty body (SHA matches empty input)"
    exit 1
fi
echo "PASS: backend received non-empty request body (sha256=${BODY_SHA})"

echo "Restoring Go EPP to simulator endpoint for the availability test."
configure_epp_backend "$SIM_IP" "8000" "simulator"

# ---------------------------------------------------------------------------
# Test 5: EPP failure -> 503 -> recovery
# ---------------------------------------------------------------------------

echo ""
echo "=== test 5: EPP failure -> 503 -> recovery ==="
echo "Scale Go EPP down. Required endpoint selection must reject with the configured"
echo "503 rather than silently forwarding or allowing failure_mode=open to bypass it."
kubectl -n "$NAMESPACE" scale deployment/go-epp --replicas=0 2>/dev/null
kubectl -n "$NAMESPACE" rollout status deployment/go-epp --timeout=30s 2>/dev/null || true

wait_for_status "503" "{\"model\":\"${V2_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"fail\"}]}" "Go EPP is unavailable"
echo "PASS: required routing rejects with the configured exact HTTP 503"

kubectl -n "$NAMESPACE" scale deployment/go-epp --replicas=1 2>/dev/null
echo "waiting for EPP recovery..."
kubectl -n "$NAMESPACE" rollout status deployment/go-epp --timeout=60s

wait_for_status "200" "{\"model\":\"${V2_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"recovered\"}],\"max_tokens\":5}" "Go EPP recovered"
echo "PASS: routing recovered after the Go EPP deployment returned"

# ---------------------------------------------------------------------------
# Test 6: No h2 resets or GOAWAY errors
# ---------------------------------------------------------------------------

echo ""
echo "=== test 6: no unexpected h2 errors ==="
echo "Inspect Praxis logs after the complete request sequence for HTTP/2 reset or GOAWAY evidence."
PRAXIS_LOGS=$(kubectl -n "$NAMESPACE" logs deployment/praxis 2>/dev/null || echo "")
RESET_COUNT=$(echo "$PRAXIS_LOGS" | grep -ci "h2.*reset\|GOAWAY\|stream reset" || true)
RESET_COUNT="${RESET_COUNT:-0}"
echo "h2 reset/GOAWAY mentions in Praxis logs: ${RESET_COUNT}"
if [[ "$RESET_COUNT" -gt 0 ]]; then
    echo "FAIL: found h2 reset/GOAWAY mentions"
    echo "$PRAXIS_LOGS" | grep -i "h2.*reset\|GOAWAY\|stream reset" || true
    exit 1
fi
echo "PASS: no h2 reset or GOAWAY evidence in Praxis logs (${RESET_COUNT} mentions)"

# ---------------------------------------------------------------------------
# Test 7: Image identity
# ---------------------------------------------------------------------------

echo ""
echo "=== test 7: image identity ==="
echo "Confirm the deployed image tag and locally built image identity recorded at preflight."
DEPLOYED_IMAGE=$(kubectl -n "$NAMESPACE" get deployment praxis -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "deployed image: ${DEPLOYED_IMAGE}"
if [[ "$DEPLOYED_IMAGE" != "$PRAXIS_IMAGE" ]]; then
    echo "FAIL: expected ${PRAXIS_IMAGE}, got ${DEPLOYED_IMAGE}"
    exit 1
fi
if [[ "${SKIP_BUILD:-}" == "1" ]]; then
    echo "PASS: deployed Praxis image tag matches the locally loaded image (source build was skipped)"
else
    echo "PASS: deployed Praxis image tag matches the image built from ${PRAXIS_SOURCE_ID}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "=== all KIND request-routing checks passed ==="
echo "cluster: ${CLUSTER_NAME}"
echo "namespace: ${NAMESPACE}"
echo "model: ${V2_MODEL}"
echo "composition: ext_proc (full_duplex_streamed) + endpoint_selector (required, 503)"
echo "validated: source provenance, routing, repeated requests, client-header distrust,"
echo "backend header stripping, non-empty forwarded body, EPP failure/recovery, h2 log hygiene"
