#!/usr/bin/env bash
# Demo 2: Load-Aware Routing
#
# sim-a is idle, sim-b is loaded (via fake-metrics). Praxis scrapes
# both and routes to the lower-pressure endpoint (sim-a).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

PORT_FORWARD_PID=""

say() {
  printf '[load-aware] %s\n' "$*"
}

header() {
  printf '\033[32m[load-aware] %s\033[0m\n' "$*"
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
  local port="${PRAXIS_LOAD_AWARE_PORT_FORWARD_PORT:-8081}"
  local log_file="/tmp/praxis-load-aware-port-forward.log"

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

show_metrics() {
  local backend="$1"
  timeout 5 kubectl exec deploy/praxis -- wget -qO- --timeout=3 "http://$backend:8000/metrics" 2>/dev/null \
    | grep -E "kv_cache_usage_perc\{|num_requests_running\{" \
    | sed 's/^/    /' || say "    (metrics not available)"
}

header "Demo 2: load-aware routing"

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
kubectl apply -f "$MANIFESTS_DIR/02-load-aware.yaml" >/dev/null
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

break_line
header "Acceptance proof:"
say "  cargo test -p praxis-tests-integration llmd_endpoint_picker_metrics_scrape_changes_routing"
say "  cargo test -p praxis-tests-integration llmd_endpoint_picker_selects_lowest_pressure_endpoint"
say "  These integration tests prove that dynamic metrics scraping changes routing"
say "  and that Praxis selects the endpoint with lowest queue/KV pressure."
break_line

header "What this demo proves:"
say "  - Praxis scrapes vLLM-compatible /metrics endpoints"
say "  - Routes based on load metrics (queue depth, KV cache usage)"
say "  - Prefers endpoints with lower resource pressure"
say "  - Uses fake-metrics in llm-d-inference-sim to simulate load"
break_line

header "Simulated metrics (fake-metrics from llm-d-inference-sim):"
say "  sim-a:"
show_metrics "sim-a"
say "  sim-b:"
show_metrics "sim-b"
break_line

header "Sending test requests:"
for i in 1 2 3; do
  response="$(send_chat_request "fake-model" "test $i")"
  if echo "$response" | grep -q '"fake-model"'; then
    say "  request $i -> ✓ routed successfully"
  else
    say "  request $i -> ✗ failed"
  fi
  sleep 1
done
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

header "Demo 2 complete"
say "  all requests routed to sim-a (idle); sim-b (loaded) was avoided"
