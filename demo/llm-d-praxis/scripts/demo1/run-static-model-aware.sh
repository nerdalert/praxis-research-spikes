#!/usr/bin/env bash
# Demo 1: Static Model-Aware Baseline
#
# sim-a serves model-a, sim-b serves model-b. Praxis routes by model field.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

PORT_FORWARD_PID=""

say() {
  printf '[model-aware] %s\n' "$*"
}

header() {
  printf '\033[32m[model-aware] %s\033[0m\n' "$*"
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
  local port="${PRAXIS_MODEL_AWARE_PORT_FORWARD_PORT:-8080}"
  local log_file="/tmp/praxis-model-aware-port-forward.log"

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

test_model_routing() {
  local model="$1"
  local expected_status="${2:-200}"
  local response
  local status

  response=$(curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
    http://localhost:"${PRAXIS_NODE_PORT}"/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}")

  status=$(echo "$response" | grep "HTTP_STATUS:" | cut -d: -f2)

  if [[ "$status" == "$expected_status" ]]; then
    say "  ✓ model '$model' -> HTTP $status"
  else
    say "  ✗ model '$model' -> HTTP $status (expected $expected_status)"
  fi
}

header "Demo 1: static model-aware routing"

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
kubectl apply -f "$MANIFESTS_DIR/01-static-model-aware.yaml" >/dev/null
kubectl wait --for=condition=ready pod -l app=sim-a --timeout=120s >/dev/null
kubectl wait --for=condition=ready pod -l app=sim-b --timeout=120s >/dev/null
kubectl wait --for=condition=ready pod -l app=praxis --timeout=120s >/dev/null
ensure_praxis_access

say "waiting for Praxis to route successfully..."
for _ in $(seq 1 20); do
  result="$(curl -s -o /dev/null -w "%{http_code}" \
    http://localhost:"${PRAXIS_NODE_PORT}"/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"model-a","messages":[{"role":"user","content":"warmup"}]}' 2>/dev/null || true)"
  if [[ "$result" == "200" ]]; then
    break
  fi
  sleep 2
done

break_line
header "Acceptance proof:"
say "  cargo test -p praxis-tests-integration llmd_endpoint_picker_filters_by_model"
say "  cargo test -p praxis-tests-integration llmd_endpoint_picker_selects_lowest_pressure_endpoint"
say "  These integration tests prove model-field extraction and model-aware"
say "  endpoint filtering with static endpoint config."
break_line

header "What this demo proves:"
say "  - Praxis extracts model field from request body"
say "  - Routes only to endpoints that serve the requested model"
say "  - Rejects requests for models not served by any endpoint"
break_line

header "Pod status:"
kubectl get pods -l 'app in (sim-a,sim-b,praxis)' --no-headers | while read line; do
  say "  $line"
done
break_line

header "Testing model-aware routing:"
test_model_routing "model-a" "200"
test_model_routing "model-b" "200"
test_model_routing "missing-model" "503"
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

header "Demo 1 complete"
say "  model-a -> sim-a, model-b -> sim-b, missing-model -> 503"
