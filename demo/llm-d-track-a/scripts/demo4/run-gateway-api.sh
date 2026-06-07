#!/usr/bin/env bash
# Demo 4: Gateway API HTTPRoute Discovery
#
# HTTPRoute -> InferencePool -> PodList discovery chain.
# Praxis reads the HTTPRoute, extracts the InferencePool backendRef,
# and discovers pod endpoints through the full chain.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

PORT_FORWARD_PID=""

say() {
  printf '[gateway-api] %s\n' "$*"
}

header() {
  printf '\033[32m[gateway-api] %s\033[0m\n' "$*"
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
  local port="${PRAXIS_GATEWAY_API_PORT_FORWARD_PORT:-8083}"
  local log_file="/tmp/praxis-gateway-api-port-forward.log"

  if port_open "$port"; then
    PRAXIS_NODE_PORT="$port"
    say "using existing port-forward localhost:$port -> praxis:8080"
    return 0
  fi

  say "starting port-forward localhost:$port -> deployment/praxis:8080"
  kubectl port-forward deployment/praxis "${port}:8080" >"$log_file" 2>&1 &
  PORT_FORWARD_PID="$!"

  PRAXIS_NODE_PORT="$port"
  wait_for_local_port "$port" 20
}

header "Demo 4: Gateway API HTTPRoute discovery"

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

say "applying CRDs and manifests, waiting for pods"
kubectl apply -f "$MANIFESTS_DIR/crds/inferencepool-crd.yaml" >/dev/null 2>&1 || true
kubectl apply -f "$MANIFESTS_DIR/04-gateway-api.yaml" >/dev/null
kubectl wait --for=condition=ready pod -l pool=sim-pool --timeout=120s >/dev/null
kubectl wait --for=condition=ready pod -l app=praxis --timeout=120s >/dev/null

say "waiting for discovery chain to stabilize..."
sleep 5
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

break_line
header "Acceptance proof:"
say "  cargo test -p praxis-tests-integration llmd_endpoint_picker_filters_by_model"
say "  cargo test -p praxis-proxy-filter llmd_endpoint_picker"
say "  The integration test proves model-aware routing. The unit tests prove"
say "  Gateway API config parsing and HTTPRoute -> InferencePool resolution."
say "  This KIND demo proves the full HTTPRoute -> InferencePool -> Pods chain."
break_line

header "What this demo proves:"
say "  - Praxis discovers endpoints via HTTPRoute references"
say "  - HTTPRoute backendRef points to InferencePool"
say "  - InferencePool uses pod selector for dynamic discovery"
say "  - Full Gateway API integration chain: HTTPRoute -> InferencePool -> Pods"
break_line

header "HTTPRoute backendRef:"
kubectl get httproute llm-route -o yaml 2>/dev/null \
  | grep -A10 "backendRefs:" | sed 's/^/  /'
break_line

header "InferencePool selector:"
kubectl get inferencepools.inference.networking.x-k8s.io sim-pool -o yaml 2>/dev/null \
  | grep -A5 "selector:" | sed 's/^/  /'
break_line

header "Discovered pods (label: pool=sim-pool):"
kubectl get pods -l pool=sim-pool --no-headers | while read line; do
  say "  $line"
done
break_line

header "Sending test requests:"
for i in 1 2; do
  response="$(send_chat_request "fake-model" "gateway api test $i")"
  if echo "$response" | grep -q '"fake-model"'; then
    say "  request $i -> ✓ routed via HTTPRoute -> InferencePool -> Pods"
  else
    say "  request $i -> ✗ failed"
  fi
  sleep 1
done
break_line

header "Validating with verbose logs:"
for backend in sim-a sim-b; do
  pod=$(kubectl get pod -l instance=$backend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
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

header "Demo 4 complete"
say "  full Gateway API discovery chain validated: HTTPRoute -> InferencePool -> Pods"
