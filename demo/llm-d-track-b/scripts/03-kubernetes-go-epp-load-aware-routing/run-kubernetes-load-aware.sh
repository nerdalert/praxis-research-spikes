#!/usr/bin/env bash
# 03 - Kubernetes Go EPP Load-Aware Routing
#
# Proves: In Kubernetes, the Go EPP scores two backends by KV cache
# utilization and selects the idle one. Praxis replaces Envoy and
# applies the Go EPP routing decision via ctx.upstream.
#
# Setup:
#   export TRACK_B_DIR=/path/to/praxis-track-b
#   export EPP_BIN=/path/to/llm-d-router/bin/epp
#   export SIM_BIN=/path/to/llm-d-inference-sim/bin/llm-d-inference-sim
#
# Usage:
#   bash scripts/03-kubernetes-go-epp-load-aware-routing/run-kubernetes-load-aware.sh
#
# Manual curl equivalent (after cluster is running):
#   curl -s -X POST http://127.0.0.1:30092/v1/chat/completions \
#     -H "Content-Type: application/json" \
#     -d '{"model":"track-b-load-aware","messages":[{"role":"user","content":"hello"}],"max_tokens":5}'
#
# Cleanup:
#   bash scripts/cleanup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

TRACK_B_IMPL_DIR="${TRACK_B_IMPL_DIR:-${TRACK_B_DIR}}"
K8S_SCRIPT="${TRACK_B_IMPL_DIR}/e2e/kind-go-epp/run-03-kubernetes-load-aware-routing.sh"

if [[ ! -f "$K8S_SCRIPT" ]]; then
  cat >&2 <<EOF

KIND load-aware script not found: $K8S_SCRIPT

Demo 03 requires the e2e/ directory. If TRACK_B_DIR points to the
track-b-benchmarking branch, clone the implementation branch:

  git clone -b track-b https://github.com/nerdalert/praxis.git praxis-track-b-impl
  export TRACK_B_IMPL_DIR="\$(pwd)/praxis-track-b-impl"
EOF
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════
header "03 - Kubernetes Go EPP Load-Aware Routing"
say "Two backends serve the same model with asymmetric load:"
say "  sim-a: idle  (kv-cache 10%, 0 running, 0 waiting)"
say "  sim-b: busy  (kv-cache 90%, 8 running, 3 waiting)"
say ""
say "Go EPP scores endpoints by KV cache utilization and picks the best."
say "Praxis calls Go EPP and applies the selected endpoint."
break_line

say "Claim boundary:"
say "  Go EPP performs load-aware endpoint selection."
say "  Praxis carries and applies the decision without Envoy."
break_line

# ═══════════════════════════════════════════════════════════════════
header "Running Kubernetes load-aware routing demo"
say "Delegating to: $K8S_SCRIPT"
say "(This may take a few minutes for image builds and cluster creation)"
break_line

cd "$TRACK_B_IMPL_DIR"
bash "$K8S_SCRIPT"

break_line
header "03 complete"
say "Run 'bash scripts/cleanup.sh' to delete the cluster."
