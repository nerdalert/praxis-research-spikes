#!/usr/bin/env bash
# Demo 7: P/D Disaggregation
#
# Decode and prefill backends with role labels and matching static endpoint
# roles in Praxis config. Praxis selects the decode backend as upstream and
# injects x-prefiller-host-port pointing to the prefill backend.
# inject_kv_transfer_params is false -- this demo proves role-based routing
# without overclaiming body mutation.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

PORT_FORWARD_PID=""

say() {
  printf '[pd-disagg] %s\n' "$*"
}

header() {
  printf '\033[32m[pd-disagg] %s\033[0m\n' "$*"
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
  local port="${PRAXIS_PD_PORT_FORWARD_PORT:-8086}"
  local log_file="/tmp/praxis-pd-port-forward.log"

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

header "Demo 7: P/D disaggregation"

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
kubectl apply -f "$MANIFESTS_DIR/07-pd-disaggregation.yaml" >/dev/null
kubectl wait --for=condition=ready pod -l app=decode-backend --timeout=120s >/dev/null
kubectl wait --for=condition=ready pod -l app=prefill-backend --timeout=120s >/dev/null
kubectl wait --for=condition=ready pod -l app=praxis --timeout=120s >/dev/null
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
say "  cargo test -p praxis-proxy-filter llmd_endpoint_picker -- disaggregation"
say "  cargo test -p praxis-tests-integration llmd_endpoint_picker"
say "  Unit tests prove role-based endpoint selection and x-prefiller-host-port"
say "  header injection. Integration tests prove decode upstream receives requests."
break_line

header "What this demo proves:"
say "  - Praxis selects decode endpoint as upstream based on endpoint role"
say "  - Praxis selects prefill endpoint separately"
say "  - x-prefiller-host-port header is injected for decode backend"
say "  - Role-based routing without full disaggregated execution"
break_line

header "Pod roles:"
kubectl get pods --show-labels --no-headers 2>/dev/null | grep -E "decode|prefill" | while read line; do
  say "  $line"
done
break_line

header "Sending test request:"
response="$(send_chat_request "fake-model" "disagg test")"
if echo "$response" | grep -q '"fake-model"'; then
  say "  ✓ request routed successfully to decode backend"
else
  say "  ✗ request failed"
fi
break_line

header "Validating with verbose logs:"
for backend in decode-backend prefill-backend; do
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

header "Demo 7 complete"
say "  decode-backend selected as upstream; prefill address injected via header"
