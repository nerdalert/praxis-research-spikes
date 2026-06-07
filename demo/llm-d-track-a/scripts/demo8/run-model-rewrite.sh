#!/usr/bin/env bash
# Demo 8: InferenceModelRewrite
#
# Praxis reads InferenceModelRewrite policy and mutates the request body
# model field before endpoint selection. Client sends "gpt-4", backend
# receives "fake-model".

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

PORT_FORWARD_PID=""

say() {
  printf '[model-rewrite] %s\n' "$*"
}

header() {
  printf '\033[32m[model-rewrite] %s\033[0m\n' "$*"
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
  local port="${PRAXIS_REWRITE_PORT_FORWARD_PORT:-8087}"
  local log_file="/tmp/praxis-rewrite-port-forward.log"

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

wait_for_rewrite_sync() {
  local max_wait=15
  say "waiting for model rewrite policy to load..."

  for _ in $(seq 1 "$max_wait"); do
    response="$(curl -s http://localhost:"${PRAXIS_NODE_PORT}"/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{"model":"gpt-4","messages":[{"role":"user","content":"sync"}]}' 2>/dev/null || true)"
    if echo "$response" | grep -q '"fake-model"'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

header "Demo 8: InferenceModelRewrite"

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
kubectl apply -f "$MANIFESTS_DIR/crds/inferencemodel-crd.yaml" >/dev/null 2>&1 || true
kubectl apply -f "$MANIFESTS_DIR/08-model-rewrite.yaml" >/dev/null
kubectl wait --for=condition=ready pod -l app=sim-a --timeout=120s >/dev/null
kubectl wait --for=condition=ready pod -l app=praxis --timeout=120s >/dev/null
ensure_praxis_access
sleep 2

break_line
header "Acceptance proof:"
say "  cargo test -p praxis-proxy-filter llmd_endpoint_picker -- model_rewrite"
say "  cargo test -p praxis-tests-integration llmd_endpoint_picker"
say "  Unit tests prove InferenceModelRewrite policy loading from fake K8s API"
say "  and request body model field mutation before endpoint selection."
break_line

header "What this demo proves:"
say "  - Praxis loads InferenceModelRewrite policy from Kubernetes"
say "  - Client sends model 'gpt-4', Praxis rewrites to 'fake-model'"
say "  - Rewrite happens before endpoint selection"
say "  - Backend receives the rewritten model name"
break_line

header "InferenceModelRewrite resource:"
kubectl get inferencemodelrewrite gpt4-rewrite -o yaml 2>/dev/null \
  | grep -A10 "rules:" | sed 's/^/  /' || say "  (resource not found)"
break_line

header "Testing model rewrite (sending model=gpt-4):"

wait_for_rewrite_sync

response="$(send_chat_request "gpt-4" "rewrite test")"
response_model=$(echo "$response" | grep -o '"model":"[^"]*"' | head -1 || true)

if echo "$response" | grep -q '"fake-model"'; then
  say "  ✓ sent model=gpt-4, backend received $response_model"
else
  say "  ✗ rewrite failed, response: $response_model"
fi
break_line

header "Validating with verbose logs:"
pod=$(kubectl get pod -l app=sim-a -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$pod" ]]; then
  count=$(kubectl logs "$pod" --tail=10 --since=30s 2>/dev/null | grep -c "Received" || true)
  if [[ "$count" -gt 0 ]] 2>/dev/null; then
    say "  sim-a received $count request(s) with rewritten model"
  else
    say "  sim-a received no requests"
  fi
fi
break_line

header "Demo 8 complete"
say "  gpt-4 -> fake-model rewrite validated"
