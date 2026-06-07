#!/usr/bin/env bash
# Example 5: Prefix-cache-aware routing.
#
# This is a compact KIND smoke demo. It shows the prefix-cache-enabled
# request path without mutating nginx pods. The route-change proof lives in
# llmd_endpoint_picker_prefix_cache_changes_routing, where metrics are managed
# by local test servers.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

PORT_FORWARD_PID=""
LAST_BACKEND=""

say() {
  printf '[prefix-cache] %s\n' "$*"
}

header() {
  printf '\033[32m[prefix-cache] %s\033[0m\n' "$*"
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
  local port="${PRAXIS_PREFIX_CACHE_PORT_FORWARD_PORT:-8085}"
  local log_file="/tmp/praxis-prefix-cache-port-forward.log"

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

extract_backend() {
  grep -o 'echo-[ab]' | head -1 || true
}

send_and_capture_backend() {
  local label="$1"
  local prompt="$2"
  local response
  local backend
  local id

  response="$(send_chat_request "fake-model" "$prompt")"
  id="$(printf '%s\n' "$response" | grep -o '"id":"[^"]*"' | head -1 || true)"
  backend="$(printf '%s\n' "$response" | extract_backend)"
  LAST_BACKEND="$backend"

  say "$label -> ${backend:-<unknown>} ${id:-}"
}

header "Demo 5: prefix-cache-aware routing"

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

say "applying manifests and waiting for pods"
kubectl apply -f "$MANIFESTS_DIR/05-prefix-cache.yaml" >/dev/null
kubectl wait --for=condition=ready pod -l app=echo-a --timeout=120s >/dev/null
kubectl wait --for=condition=ready pod -l app=echo-b --timeout=120s >/dev/null
kubectl wait --for=condition=ready pod -l app=praxis --timeout=120s >/dev/null
ensure_praxis_access

break_line
say "model: in-memory prefix index in Praxis; no real vLLM KV introspection"
break_line
header "Acceptance proof:"
say "  cargo test -p praxis-tests-integration llmd_endpoint_picker_prefix_cache_changes_routing"
say "  In that Praxis integration test, metrics are managed by local test servers."
say "  The test seeds a prefix, changes endpoint pressure through those metrics,"
say "  and proves a repeated prefix can override normal load scoring."
break_line

PREFIX_A="Tell me about Kubernetes operators and how they extend the control plane with custom resources and controllers"
PREFIX_B="Explain the CAP theorem in distributed systems and its implications for database design and consistency"

header "KIND smoke output:"
send_and_capture_backend "request 1 prompt A seeds index" "$PREFIX_A"
BACKEND1="$LAST_BACKEND"

send_and_capture_backend "request 2 prompt A repeats" "$PREFIX_A"
BACKEND2="$LAST_BACKEND"

if [[ -n "$BACKEND1" && "$BACKEND1" == "$BACKEND2" ]]; then
  say "result: prompt A stayed on $BACKEND1"
else
  say "result: prompt A moved from ${BACKEND1:-<none>} to ${BACKEND2:-<none>}"
fi

break_line
send_and_capture_backend "request 3 prompt B differs" "$PREFIX_B"
BACKEND3="$LAST_BACKEND"

if [[ "$BACKEND3" == "$BACKEND1" ]]; then
  say "note: prompt B also hit $BACKEND3; deterministic baseline can hide prefix effects"
else
  say "note: prompt B hit $BACKEND3; prompt A history did not force this request"
fi
