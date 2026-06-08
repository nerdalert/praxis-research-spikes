# Deployment Guide

## Prerequisites

| Tool | Minimum | Check Command |
|------|---------|---------------|
| Docker | 29.x+ | `docker --version` |
| kind | 0.20+ | `kind --version` |
| kubectl | 1.28+ | `kubectl version --client` |
| Rust | 1.94+ stable | `rustc --version` |
| Go | 1.21+ | `go version` |

Verify all tools are available:

```bash
docker --version
kind --version
kubectl version --client
rustc --version
go version
```

## Source Repositories

Clone the repositories needed for the demo:

```bash
# Praxis with full native llm-d endpoint picker implementation
git clone https://github.com/nerdalert/praxis.git praxis-demo
cd praxis-demo
git checkout e2e-llm-d-epp

# llm-d-inference-sim (the simulator)
git clone https://github.com/llm-d/llm-d-inference-sim.git llm-d-inference-sim
```

- **Praxis branch**: [`e2e-llm-d-epp`](https://github.com/nerdalert/praxis/tree/e2e-llm-d-epp) — full native Praxis llm-d endpoint picker implementation snapshot for demo and E2E validation.
- **PR**: https://github.com/nerdalert/praxis/pull/new/e2e-llm-d-epp

Set environment variables (or accept defaults):

```bash
export PRAXIS_DIR="${PRAXIS_DIR:-$(pwd)/praxis-demo}"
export LLM_D_INFERENCE_SIM_DIR="${LLM_D_INFERENCE_SIM_DIR:-$(pwd)/llm-d-inference-sim}"
export KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-praxis-llmd-demo}"
export PRAXIS_NODE_PORT="${PRAXIS_NODE_PORT:-30081}"
export PRAXIS_IMAGE="${PRAXIS_IMAGE:-praxis-epp:dev}"
export SIM_IMAGE="${SIM_IMAGE:-ghcr.io/llm-d/llm-d-inference-sim:dev}"
```

---

## Quick Start (One Command)

Run the entire demo end-to-end:

```bash
bash run-complete-e2e-demo.sh
```

This creates the KIND cluster, builds images, runs all examples, captures
output to `sample-output.md`, and cleans up.

To keep the cluster after the run (for manual exploration):

```bash
SKIP_CLEANUP=1 bash run-complete-e2e-demo.sh
```

---

## Manual Setup

### Step 1: Create KIND Cluster

```bash
bash scripts/create-kind.sh
```

Verify:

```bash
kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}"
kubectl get nodes
```

### Step 2: Build and Load Images

**IMPORTANT**: Both images must be built and loaded into KIND before running any examples.

```bash
# Build and load images using the provided script
bash scripts/build-and-load-images.sh
```

Or manually build and load each image:

```bash
# Build Praxis image with llmd_endpoint_picker support
cd "${PRAXIS_DIR}"
docker build -t praxis-epp:dev -f Containerfile .
kind load docker-image praxis-epp:dev --name "${KIND_CLUSTER_NAME}"

# Build and load inference simulator image
cd "${LLM_D_INFERENCE_SIM_DIR}" 
docker build -t ghcr.io/llm-d/llm-d-inference-sim:dev .
kind load docker-image ghcr.io/llm-d/llm-d-inference-sim:dev --name "${KIND_CLUSTER_NAME}"
```

Verify images are loaded:

```bash
docker exec "${KIND_CLUSTER_NAME}-control-plane" crictl images | grep -E "(praxis-epp|inference-sim)"
```

### Step 3: Run Individual Examples

Each example can be run independently after Steps 1-2 using **automated demo scripts**:

```bash
# Self-narrated demo scripts with automatic validation
bash scripts/demo1/run-static-model-aware.sh
bash scripts/demo2/run-load-aware.sh
bash scripts/demo3/run-inferencepool-discovery.sh
bash scripts/demo4/run-gateway-api.sh
bash scripts/demo5/run-prefix-cache.sh

# Legacy scripts (still available)
bash scripts/run-saturation.sh
bash scripts/run-pd-disaggregation.sh
bash scripts/run-model-rewrite.sh
bash scripts/run-inference-objective.sh
```

Each script applies its manifests, waits for pods, sends test requests,
and prints evidence. Scripts do not clean up after themselves — use
the cleanup script between examples to reset state:

```bash
bash scripts/cleanup.sh
```

---

## Demo Infrastructure

These examples use **llm-d-inference-sim** to simulate model servers without requiring actual LLMs or GPUs. Key features:

- **fake-metrics**: Simulates vLLM/SGLang metrics (queue depth, KV cache usage, request counts) without real load
- **echo mode**: Returns request metadata to validate routing decisions  
- **model simulation**: Advertises served models for endpoint eligibility testing
- **verbose logging**: Uses `--v=5` flag to enable request processing logs for validation

**Production vs Demo**:
- **Demo**: `fake-metrics` in simulator configs creates artificial load patterns
- **Production**: Real vLLM/SGLang/TensorRT-LLM servers expose actual metrics
- **Praxis behavior**: Identical - scrapes `/metrics` endpoints and routes based on values found

**Validation**: Verbose logging shows which simulator receives requests, proving routing decisions work correctly without needing to generate real GPU load.

## KIND Cluster Networking

**Important**: These demos are designed for **KIND (Kubernetes in Docker)** clusters and use **localhost port-forwarding** for client access:

- **NodePort services** (port 30081) do NOT work reliably in KIND clusters
- **Use `kubectl port-forward`** to access services from localhost
- **All curl commands** target `http://localhost:<port>` after establishing port-forward
- **Port-forwarding is required** for each demo to test Praxis routing behavior

Each demo includes the correct port-forwarding setup commands.

---

## Per-Example Commands

### Example 1: Static Model-Aware Baseline

**Prerequisites**: Images must be built and loaded first (see Step 2 above).

#### **Automated Demo Script**

```bash
# Run the self-narrated demo script
bash scripts/demo1/run-static-model-aware.sh
```

#### **Manual Commands**

```bash
# Clean up any previous failed pods
kubectl delete -f manifests/01-static-model-aware.yaml --ignore-not-found=true

# Apply manifests
kubectl apply -f manifests/01-static-model-aware.yaml

# Wait for pods to be ready (may take 60-120s on first run)
kubectl wait --for=condition=ready pod -l app=sim-a --timeout=120s
kubectl wait --for=condition=ready pod -l app=sim-b --timeout=120s
kubectl wait --for=condition=ready pod -l app=praxis --timeout=120s

# Start port forwarding
PRAXIS_POD=$(kubectl get pod -l app=praxis -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward pod/$PRAXIS_POD 8080:8080 &
sleep 3

# Test model-a (should succeed and route to sim-a)
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"model-a","messages":[{"role":"user","content":"hello"}]}'

# Test model-b (should succeed and route to sim-b) 
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"model-b","messages":[{"role":"user","content":"hello"}]}'

# Test missing model (should fail with 502/503)
curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
  http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"missing-model","messages":[{"role":"user","content":"hello"}]}'

# Validate with logs
kubectl logs deployment/sim-a --tail=5 --since=30s | grep -E "Received|Finished" || echo "No sim-a requests"
kubectl logs deployment/sim-b --tail=5 --since=30s | grep -E "Received|Finished" || echo "No sim-b requests"

# Cleanup
pkill -f "kubectl port-forward"
```

### Example 2: Load-Aware Routing

**Note**: This demo uses **fake-metrics** in llm-d-inference-sim to simulate different load levels without actual traffic. sim-a reports idle metrics (running=0, kv-cache=0%), sim-b reports busy metrics (running=5, kv-cache=50%). The simulators run with `--v=5` verbose logging to show request processing for validation.

#### **Automated Demo Script**

```bash
# Run the self-narrated demo script
bash scripts/demo2/run-load-aware.sh
```

#### **Manual Commands**

```bash
kubectl apply -f manifests/02-load-aware.yaml

kubectl wait --for=condition=ready pod -l app=sim-a --timeout=120s
kubectl wait --for=condition=ready pod -l app=sim-b --timeout=120s
kubectl wait --for=condition=ready pod -l app=praxis --timeout=120s

# Wait for metrics scrape cycle
sleep 3

# Verify simulated metrics that Praxis sees
echo "=== sim-a metrics (should show low load) ==="
kubectl exec deploy/praxis -- wget -qO- http://sim-a:8000/metrics | grep "kv_cache_usage_perc\|num_requests_running"
echo "=== sim-b metrics (should show high load) ==="
kubectl exec deploy/praxis -- wget -qO- http://sim-b:8000/metrics | grep "kv_cache_usage_perc\|num_requests_running"

# Send test requests to trigger routing
echo "=== Testing load-aware routing ==="
for i in $(seq 1 3); do
  curl -s http://localhost:30081/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"fake-model","messages":[{"role":"user","content":"test '$i'"}]}' > /dev/null
  echo "Request $i sent"
done

# Validate routing with verbose logs
echo "=== sim-a logs (should show request processing) ==="
kubectl logs deployment/sim-a --tail=5 --since=60s

echo "=== sim-b logs (should be silent - no requests) ==="  
kubectl logs deployment/sim-b --tail=5 --since=60s
```

**Expected validation result:**
- **sim-a logs**: Show `"Received" new HTTP="chat completion request"` entries
- **sim-b logs**: Only startup logs, no request processing logs
- **Proves**: All traffic routes to sim-a (low metrics) and avoids sim-b (high metrics)

### Example 3: InferencePool Discovery

**Note**: This demo uses **InferencePool CRD** for dynamic endpoint discovery instead of static endpoint configuration. Pods are labeled with `pool=sim-pool` and discovered via Kubernetes API. Simulators run with `--v=5` for request validation logging.

#### **Automated Demo Script**

```bash
# Run the self-narrated demo script
bash scripts/demo3/run-inferencepool-discovery.sh
```

#### **Manual Commands**

```bash
# Install CRDs first
kubectl apply -f manifests/crds/inferencepool-crd.yaml

kubectl apply -f manifests/03-inferencepool-discovery.yaml

kubectl wait --for=condition=ready pod -l pool=sim-pool --timeout=120s
kubectl wait --for=condition=ready pod -l app=praxis --timeout=120s

# Verify InferencePool resource and discovered pods
echo "=== InferencePool resource ==="
kubectl get inferencepools.inference.networking.x-k8s.io sim-pool -o yaml | grep -A10 "spec:"

echo "=== Discovered pods ==="
kubectl get pods -l pool=sim-pool -o wide

# Start port forwarding
PRAXIS_POD=$(kubectl get pod -l app=praxis -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward pod/$PRAXIS_POD 8083:8080 &
sleep 3

# Test dynamic endpoint discovery
for i in {1..2}; do
  curl -s http://localhost:8083/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"fake-model","messages":[{"role":"user","content":"test '$i'"}]}' > /dev/null
  echo "Request $i sent"
done

# Validate with logs (shows which pod received requests)
echo "=== Request routing validation ==="
kubectl logs deployment/sim-a --tail=5 --since=30s | grep "Received\|Finished" || echo "No sim-a requests"
kubectl logs deployment/sim-b --tail=5 --since=30s | grep "Received\|Finished" || echo "No sim-b requests"

# Cleanup
pkill -f "kubectl port-forward"
```

**Expected validation result:**
- **InferencePool**: Shows selector `app=llm-d-sim, pool=sim-pool`
- **Pod discovery**: Lists 2 pods matching the selector
- **Request logs**: Shows which simulator pod(s) received the routed requests
- **Proves**: Praxis dynamically discovers endpoints via InferencePool instead of static config

### Example 4: Gateway API HTTPRoute

**Note**: This demo uses **Gateway API HTTPRoute** discovery chain: HTTPRoute → InferencePool → PodList. Praxis reads the HTTPRoute, extracts InferencePool backendRef, then discovers pods. Simulators run with `--v=5` verbose logging.

#### **Automated Demo Script**

```bash
# Run the self-narrated demo script
bash scripts/demo4/run-gateway-api.sh
```

#### **Manual Commands**

```bash
# HTTPRoute CRD already exists, apply Demo 4
kubectl apply -f manifests/04-gateway-api.yaml

kubectl wait --for=condition=ready pod -l pool=sim-pool --timeout=120s
kubectl wait --for=condition=ready pod -l app=praxis --timeout=120s

# Verify Gateway API discovery chain
echo "=== HTTPRoute backendRef ==="
kubectl get httproute llm-route -o yaml | grep -A10 "backendRefs:"

echo "=== InferencePool selector ==="
kubectl get inferencepools.inference.networking.x-k8s.io sim-pool -o yaml | grep -A5 "selector:"

echo "=== Discovered pods ==="
kubectl get pods -l pool=sim-pool -o wide

# Start port forwarding and test
PRAXIS_POD=$(kubectl get pod -l app=praxis -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward pod/$PRAXIS_POD 8084:8080 &
sleep 3

# Test Gateway API discovery
for i in {1..2}; do
  curl -s http://localhost:8084/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"fake-model","messages":[{"role":"user","content":"test '$i'"}]}' > /dev/null
  echo "Request $i sent"
done

# Validate routing with logs  
echo "=== Gateway API routing validation ==="
kubectl logs deployment/sim-a --tail=5 --since=30s | grep "Received\|Finished" || echo "No sim-a requests"
kubectl logs deployment/sim-b --tail=5 --since=30s | grep "Received\|Finished" || echo "No sim-b requests"

# Cleanup
pkill -f "kubectl port-forward"
```

**Expected validation result:**
- **HTTPRoute**: Shows backendRef pointing to `InferencePool/sim-pool`
- **InferencePool**: Shows selector `app=llm-d-sim, pool=sim-pool`  
- **Pod discovery**: Lists 2 pods matching the selector
- **Request logs**: Shows routing through the Gateway API → InferencePool → Pod discovery chain
- **Proves**: Praxis can discover endpoints via Gateway API HTTPRoute references

### Example 5: Prefix-Cache-Aware Routing

**Note**: This demo uses **nginx echo backends** that return static JSON responses with unique IDs (`chatcmpl-echo-a` vs `chatcmpl-echo-b`) to identify which backend handled requests. Praxis prefix-cache is enabled with high weight (10.0). The KIND script is a narrated smoke demo and intentionally does not mutate nginx pods. The stronger route-change proof is the Praxis integration test `llmd_endpoint_picker_prefix_cache_changes_routing`, where metrics are managed by local test servers so endpoint pressure can be changed deterministically.

#### **Automated Demo Script**

```bash
# Run the self-narrated demo script
bash scripts/demo5/run-prefix-cache.sh
```

#### **Manual Commands**

The script uses the KIND demo convention:
`kubectl port-forward deployment/praxis 8085:8080`. If that
port-forward is already running, the script reuses it. Otherwise it
starts it.

```bash
bash scripts/run-prefix-cache.sh
```

**Expected validation result:**
- **Backend availability**: echo-a returns `"id":"chatcmpl-echo-a"`, echo-b returns `"id":"chatcmpl-echo-b"`
- **KIND smoke demo**: prompt A is sent twice and backend identity is printed
- **Caveat**: identical deterministic routing can hide prefix-cache effects
- **Acceptance proof**: `llmd_endpoint_picker_prefix_cache_changes_routing` uses managed local metrics servers to change endpoint pressure and prove prefix affinity can override load scoring

### Example 6: Saturation/Admission Gate

**Note**: Uses fake-metrics to simulate different saturation levels. The admission gate evaluates simulated load metrics to demonstrate saturation-based request rejection.

```bash
kubectl apply -f manifests/06-saturation.yaml

kubectl wait --for=condition=ready pod -l app=sim-a --timeout=120s
kubectl wait --for=condition=ready pod -l app=sim-b --timeout=120s
kubectl wait --for=condition=ready pod -l app=praxis --timeout=120s

sleep 3

# Should route to the healthy endpoint
curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
  http://localhost:30081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"fake-model","messages":[{"role":"user","content":"hello"}]}'
```

### Example 7: P/D Disaggregation

```bash
kubectl apply -f manifests/07-pd-disaggregation.yaml

kubectl wait --for=condition=ready pod -l app=decode-backend --timeout=120s
kubectl wait --for=condition=ready pod -l app=prefill-backend --timeout=120s
kubectl wait --for=condition=ready pod -l app=praxis --timeout=120s

sleep 2

curl -s http://localhost:30081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"fake-model","messages":[{"role":"user","content":"hello"}]}'
```

### Example 8: InferenceModelRewrite

```bash
kubectl apply -f manifests/crds/inferencemodel-crd.yaml

kubectl apply -f manifests/08-model-rewrite.yaml

kubectl wait --for=condition=ready pod -l app=sim-a --timeout=120s
kubectl wait --for=condition=ready pod -l app=praxis --timeout=120s

sleep 3

# Request with gpt-4, which gets rewritten to fake-model
curl -s http://localhost:30081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"hello"}]}'
```

### Example 9: InferenceObjective

```bash
kubectl apply -f manifests/crds/inferenceobjective-crd.yaml

kubectl apply -f manifests/09-inference-objective.yaml

kubectl wait --for=condition=ready pod -l app=sim-a --timeout=120s
kubectl wait --for=condition=ready pod -l app=praxis --timeout=120s

sleep 5

# Request with x-llm-d-inference-objective header
curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
  http://localhost:30081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'x-llm-d-inference-objective: high-priority' \
  -d '{"model":"fake-model","messages":[{"role":"user","content":"hello"}]}'
```

---

## Troubleshooting

### inotify limit exhaustion

If `kind create cluster` fails with inotify errors:

```bash
sudo sysctl fs.inotify.max_user_instances=512
sudo sysctl fs.inotify.max_user_watches=1048576
```

### Port 30081 already in use

If another KIND cluster is using port 30081:

```bash
export PRAXIS_NODE_PORT=30082
bash scripts/create-kind.sh
```

### Praxis pod CrashLoopBackOff

Check logs:

```bash
kubectl logs -l app=praxis --tail=50
```

Common causes:
- Config YAML syntax error in the ConfigMap.
- Missing CRD (InferencePool, HTTPRoute) for discovery-based examples.
- Image not loaded into KIND (`kind load docker-image`).

### ErrImageNeverPull errors

If pods show `ErrImageNeverPull` status:

```bash
# Check if images are loaded in kind cluster
docker exec "${KIND_CLUSTER_NAME}-control-plane" crictl images | grep -E "(praxis-epp|inference-sim)"

# If missing, build and load images
cd "${PRAXIS_DIR}"
docker build -t praxis-epp:dev -f Containerfile .
kind load docker-image praxis-epp:dev --name "${KIND_CLUSTER_NAME}"

# Delete and reapply manifests  
kubectl delete -f manifests/01-static-model-aware.yaml --ignore-not-found=true
kubectl apply -f manifests/01-static-model-aware.yaml
```

### Metrics scrape failures at startup

The Praxis log may show WARN lines like:

```
WARN  ...state: metrics scrape failed, marking endpoint unhealthy
```

These are normal at startup when sim pods are not yet ready. After
the first successful scrape, no further failures should appear.

### Simulator pods not starting

Verify the image is loaded:

```bash
docker exec "${KIND_CLUSTER_NAME}-control-plane" crictl images | grep inference-sim
```

If missing, rebuild and reload:

```bash
bash scripts/build-and-load-images.sh
```

### Podman / Docker compatibility

On hosts where podman is the default container runtime, transfer
images to Docker before loading into KIND:

```bash
podman save praxis-epp:dev | docker load
kind load docker-image praxis-epp:dev --name "${KIND_CLUSTER_NAME}"
```

---

## Cleanup

Remove the KIND cluster and all resources:

```bash
bash scripts/cleanup.sh
```

Or manually:

```bash
kind delete cluster --name "${KIND_CLUSTER_NAME:-praxis-llmd-demo}"
```
