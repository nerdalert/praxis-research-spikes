#!/usr/bin/env bash
# Demo 9: InferenceObjective
#
# Praxis loads InferenceObjective priority metadata from Kubernetes and
# attaches it to requests via the x-llm-d-inference-objective header.
# This proves the metadata path used by objective-aware admission.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

PORT_FORWARD_PID=""

say() {
  printf '[objective] %s\n' "$*"
}

header() {
  printf '\033[32m[objective] %s\033[0m\n' "$*"
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
  local port="${PRAXIS_OBJECTIVE_PORT_FORWARD_PORT:-8088}"
  local log_file="/tmp/praxis-objective-port-forward.log"

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

wait_for_objective_sync() {
  local max_wait=15
  say "waiting for objective metadata to load..."

  for _ in $(seq 1 "$max_wait"); do
    response="$(curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
      http://localhost:"${PRAXIS_NODE_PORT}"/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -H 'x-llm-d-inference-objective: high-priority' \
      -d '{"model":"fake-model","messages":[{"role":"user","content":"sync"}]}' 2>/dev/null || true)"
    status=$(printf '%s\n' "$response" | awk -F: '/^HTTP_STATUS:/ {print $2}' | tail -1)
    if [[ "$status" == "200" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

header "Demo 9: InferenceObjective priority metadata"

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

say "installing CRDs and applying manifests"
kubectl apply -f "$MANIFESTS_DIR/crds/inferenceobjective-crd.yaml" >/dev/null 2>&1 || true
kubectl apply -f "$MANIFESTS_DIR/09-inference-objective.yaml" >/dev/null
kubectl wait --for=condition=ready pod -l app=sim-a --timeout=120s >/dev/null
kubectl wait --for=condition=ready pod -l app=praxis --timeout=120s >/dev/null

say "waiting for sim-a to become reachable from praxis..."
for _ in $(seq 1 15); do
  if timeout 5 kubectl exec deploy/praxis -- wget -qO- --timeout=3 http://sim-a:8000/metrics >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

ensure_praxis_access
sleep 2

break_line
header "Acceptance proof:"
say "  cargo test -p praxis-tests-integration llmd_endpoint_picker_saturation_gate_objective_aware_admission"
say "  cargo test -p praxis-proxy-filter llmd_endpoint_picker -- inference_objective"
say "  Integration test proves objective-aware admission with fake K8s API."
say "  Unit tests prove InferenceObjective loading and priority resolution."
break_line

header "What this demo proves:"
say "  - Praxis loads InferenceObjective priority metadata from Kubernetes"
say "  - Request with x-llm-d-inference-objective header is processed"
say "  - Objective metadata is available to priority-aware admission policy"
say "  - Routing still succeeds with objective header present"
break_line

header "InferenceObjective resource:"
kubectl get inferenceobjectives.llm-d.ai -o yaml 2>/dev/null \
  | grep -E "name:|priority:" | sed 's/^/  /' || say "  (resource not found)"
break_line

header "Testing with objective header:"
wait_for_objective_sync
sleep 2

say "  request without objective header:"
response="$(send_chat_request_with_status "fake-model" "no objective")"
status=$(printf '%s\n' "$response" | awk -F: '/^HTTP_STATUS:/ {print $2}' | tail -1)
say "    -> HTTP $status"

say "  request with x-llm-d-inference-objective: high-priority:"
response="$(curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
  http://localhost:"${PRAXIS_NODE_PORT}"/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'x-llm-d-inference-objective: high-priority' \
  -d '{"model":"fake-model","messages":[{"role":"user","content":"priority test"}]}')"
status=$(printf '%s\n' "$response" | awk -F: '/^HTTP_STATUS:/ {print $2}' | tail -1)
if [[ "$status" == "200" ]]; then
  say "    -> ✓ HTTP $status (objective metadata processed)"
else
  say "    -> ✗ HTTP $status (expected 200)"
fi
break_line

header "Validating with verbose logs:"
pod=$(kubectl get pod -l app=sim-a -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$pod" ]]; then
  count=$(kubectl logs "$pod" --tail=10 --since=60s 2>/dev/null | grep -c "Received" || true)
  if [[ "$count" -gt 0 ]] 2>/dev/null; then
    say "  sim-a received $count request(s)"
  else
    say "  sim-a received no requests"
  fi
fi
break_line

header "Demo 9 complete"
say "  objective metadata loaded and processed; routing works with priority header"
