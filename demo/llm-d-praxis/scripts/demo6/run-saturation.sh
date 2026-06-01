#!/usr/bin/env bash
# Demo 6: Saturation/Admission Gate
#
# sim-a is healthy, sim-b is saturated (via fake-metrics). Praxis filters
# overloaded endpoints and routes to the healthy one. A second config
# saturates both endpoints and proves the 429 pool rejection path.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

PORT_FORWARD_PID=""

say() {
  printf '[saturation] %s\n' "$*"
}

header() {
  printf '\033[32m[saturation] %s\033[0m\n' "$*"
}

break_line() {
  printf '\n'
}

cleanup_port_forward() {
  if [[ -n "$PORT_FORWARD_PID" ]]; then
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
  fi
}

trap cleanup_port_forward EXIT

port_open() {
  local port="$1"
  (echo >"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1
}

wait_for_local_port() {
  local port="$1"
  local max_wait="${2:-20}"

  for _ in $(seq 1 "$max_wait"); do
    if port_open "$port"; then
      return 0
    fi
    sleep 1
  done

  say "ERROR: localhost:$port did not become ready"
  return 1
}

ensure_praxis_access() {
  local port="${PRAXIS_SATURATION_PORT_FORWARD_PORT:-8084}"
  local log_file="/tmp/praxis-saturation-port-forward.log"

  cleanup_port_forward
  PORT_FORWARD_PID=""

  say "starting port-forward localhost:$port -> deployment/praxis:8080"
  kubectl port-forward deployment/praxis "${port}:8080" >"$log_file" 2>&1 &
  PORT_FORWARD_PID="$!"

  PRAXIS_NODE_PORT="$port"
  wait_for_local_port "$port" 20
}

wait_for_metrics() {
  local backend="$1"
  local max_wait=15

  for _ in $(seq 1 "$max_wait"); do
    if timeout 5 kubectl exec deploy/praxis -- wget -qO- --timeout=3 "http://$backend:8000/metrics" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

header "Demo 6: saturation/admission gate"

say "cleaning up previous demo resources..."
kubectl delete deployment praxis sim-a sim-b echo-a echo-b decode-backend prefill-backend --ignore-not-found >/dev/null 2>&1 || true
kubectl delete service praxis sim-a sim-b echo-a echo-b decode-backend prefill-backend --ignore-not-found >/dev/null 2>&1 || true
kubectl delete configmap praxis-config sim-a-config sim-b-config echo-a-config echo-b-config --ignore-not-found >/dev/null 2>&1 || true
kubectl delete serviceaccount praxis-sa --ignore-not-found >/dev/null 2>&1 || true
kubectl delete clusterrolebinding praxis-discovery --ignore-not-found >/dev/null 2>&1 || true
kubectl delete clusterrole praxis-discovery --ignore-not-found >/dev/null 2>&1 || true
kubectl delete inferencepool sim-pool --ignore-not-found >/dev/null 2>&1 || true
kubectl delete httproute llm-route --ignore-not-found >/dev/null 2>&1 || true
kubectl delete inferencemodelrewrite gpt4-rewrite --ignore-not-found >/dev/null 2>&1 || true
kubectl delete inferenceobjective high-priority --ignore-not-found >/dev/null 2>&1 || true
kubectl wait --for=delete pod -l app=praxis --timeout=30s >/dev/null 2>&1 || true

say "applying manifests and waiting for pods"
kubectl apply -f "$MANIFESTS_DIR/06-saturation.yaml" >/dev/null
kubectl wait --for=condition=ready pod -l app=sim-a --timeout=120s >/dev/null
kubectl wait --for=condition=ready pod -l app=sim-b --timeout=120s >/dev/null
kubectl wait --for=condition=ready pod -l app=praxis --timeout=120s >/dev/null

say "waiting for metrics endpoints to become reachable..."
wait_for_metrics "sim-a"
wait_for_metrics "sim-b"

ensure_praxis_access

say "waiting for Praxis to route successfully..."
for _ in $(seq 1 20); do
  result="$(curl -s -o /dev/null -w "%{http_code}" \
    http://localhost:"${PRAXIS_NODE_PORT}"/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"fake-model","messages":[{"role":"user","content":"warmup"}]}' 2>/dev/null || true)"
  if [[ "$result" == "200" ]]; then
    break
  fi
  sleep 2
done
sleep 2

break_line
header "Acceptance proof:"
say "  cargo test -p praxis-tests-integration llmd_endpoint_picker_saturation_gate_rejects_when_saturated"
say "  cargo test -p praxis-tests-integration llmd_endpoint_picker_saturation_gate_routes_to_healthy"
say "  These integration tests prove the saturation gate rejects fully saturated"
say "  pools and routes to healthy endpoints when partial saturation exists."
break_line

header "What this demo proves:"
say "  - Praxis evaluates endpoint saturation from queue depth and KV cache usage"
say "  - Filters overloaded endpoints before scoring"
say "  - Routes to the healthy endpoint when partial saturation exists"
say "  - Returns HTTP 429 when the entire pool is saturated"
break_line

header "Phase 1: mixed saturation (sim-a healthy, sim-b saturated):"
response="$(send_chat_request_with_status "fake-model" "saturation test")"
status=$(printf '%s\n' "$response" | awk -F: '/^HTTP_STATUS:/ {print $2}' | tail -1)
if [[ "$status" == "200" ]]; then
  say "  ✓ request admitted -> HTTP $status (routed to healthy sim-a)"
else
  say "  ✗ request returned HTTP $status (expected 200)"
fi
break_line

header "Validating with verbose logs:"
for backend in sim-a sim-b; do
  pod=$(kubectl get pod -l app=$backend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [[ -n "$pod" ]]; then
    count=$(kubectl logs "$pod" --tail=10 --since=30s 2>/dev/null | grep -c "Received" || true)
    if [[ "$count" -gt 0 ]] 2>/dev/null; then
      say "  $backend received $count request(s)"
    else
      say "  $backend received no requests"
    fi
  fi
done
break_line

header "Phase 2: full pool saturation (both endpoints saturated -> 429):"
say "applying saturated config..."
cleanup_port_forward
PORT_FORWARD_PID=""

kubectl apply -f "$MANIFESTS_DIR/06b-saturation-reject.yaml" >/dev/null
kubectl rollout restart deployment/sim-a deployment/sim-b deployment/praxis >/dev/null
kubectl wait --for=condition=ready pod -l app=sim-a --timeout=120s >/dev/null
kubectl wait --for=condition=ready pod -l app=sim-b --timeout=120s >/dev/null
kubectl wait --for=condition=ready pod -l app=praxis --timeout=120s >/dev/null

say "waiting for saturated metrics to propagate..."
wait_for_metrics "sim-a"
wait_for_metrics "sim-b"

ensure_praxis_access

say "waiting for Praxis scraper to ingest saturated metrics..."
for _ in $(seq 1 15); do
  result="$(curl -s -o /dev/null -w "%{http_code}" \
    http://localhost:"${PRAXIS_NODE_PORT}"/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"fake-model","messages":[{"role":"user","content":"warmup"}]}' 2>/dev/null || true)"
  if [[ "$result" == "429" ]]; then
    break
  fi
  sleep 1
done

response="$(send_chat_request_with_status "fake-model" "reject test")"
status=$(printf '%s\n' "$response" | awk -F: '/^HTTP_STATUS:/ {print $2}' | tail -1)
if [[ "$status" == "429" ]]; then
  say "  ✓ request rejected -> HTTP $status (pool saturated)"
else
  say "  ✗ request returned HTTP $status (expected 429)"
fi
break_line

header "Demo 6 complete"
say "  healthy pool -> HTTP 200 (routed to sim-a)"
say "  saturated pool -> HTTP 429 (rejected)"
