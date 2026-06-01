#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Check prerequisites for the llm-d Praxis demo.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

log_section "Checking prerequisites"

MISSING=0

check_tool() {
  local name="$1"
  local cmd="$2"
  if command -v "$name" >/dev/null 2>&1; then
    local version
    version="$($cmd 2>&1 | head -1)"
    log "OK: $name — $version"
  else
    log "MISSING: $name"
    MISSING=$((MISSING + 1))
  fi
}

check_tool docker  "docker --version"
check_tool kind    "kind --version"
check_tool kubectl "kubectl version --client --short"
check_tool rustc   "rustc --version"
check_tool cargo   "cargo --version"
check_tool go      "go version"
check_tool curl    "curl --version"

echo

if [[ ! -d "$PRAXIS_DIR" ]]; then
  log "MISSING: Praxis directory not found at $PRAXIS_DIR"
  log "  Set PRAXIS_DIR or clone: git clone https://github.com/praxis-proxy/praxis.git $PRAXIS_DIR"
  MISSING=$((MISSING + 1))
else
  log "OK: Praxis directory — $PRAXIS_DIR"
fi

if [[ ! -d "$LLM_D_INFERENCE_SIM_DIR" ]]; then
  log "MISSING: llm-d-inference-sim directory not found at $LLM_D_INFERENCE_SIM_DIR"
  log "  Set LLM_D_INFERENCE_SIM_DIR or clone: git clone https://github.com/llm-d/llm-d-inference-sim.git $LLM_D_INFERENCE_SIM_DIR"
  MISSING=$((MISSING + 1))
else
  log "OK: llm-d-inference-sim directory — $LLM_D_INFERENCE_SIM_DIR"
fi

echo

if [[ "$MISSING" -gt 0 ]]; then
  log "ERROR: $MISSING prerequisite(s) missing. See above."
  exit 1
fi

log "All prerequisites satisfied."
