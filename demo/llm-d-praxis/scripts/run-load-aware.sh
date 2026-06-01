#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Example 2: Load-Aware Routing
#
# Proves Praxis scrapes vLLM /metrics and routes to the lower-pressure
# backend based on queue depth and KV-cache utilization.
#
# The load values come from llm-d-inference-sim fake-metrics. Praxis
# scrapes them exactly like production vLLM/SGLang metrics.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

log_section "Example 2: Load-Aware Routing"

apply_manifests "$MANIFESTS_DIR/02-load-aware.yaml"

wait_for_pods "app=sim-a"
wait_for_pods "app=sim-b"
wait_for_pods "app=praxis"

wait_for_port "$PRAXIS_NODE_PORT" "Praxis NodePort"

wait_for_metrics_scrape 5

log "Simulator fake-metrics:"
log "  sim-a: running=0, waiting=0, kv=0% (idle)"
log "  sim-b: running=5, waiting=2, kv=50% (busy)"
log "Praxis treats these as normal Prometheus /metrics values."
echo

log "Sending 5 requests — all should route to sim-a (lower pressure) ..."
echo

for i in $(seq 1 5); do
  log "Request $i:"
  RESPONSE="$(send_chat_request "fake-model" "test-$i")"
  echo "$RESPONSE"
  echo
done

log "Checking Praxis logs for endpoint selection ..."
show_praxis_logs 20

log "Example 2 complete."
log ""
log "Evidence: sim-a has running=0/waiting=0/kv=0%, sim-b has"
log "running=5/waiting=2/kv=50%. All requests should route to sim-a."
log "Note: these are llm-d-inference-sim fake metrics for deterministic demo load."
