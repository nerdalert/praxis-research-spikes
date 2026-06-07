#!/usr/bin/env bash
# Check prerequisites for Track B demos.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=demo/llm-d-track-b/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

echo "=== Track B Prerequisites ==="

ok=true
for cmd in cargo go docker kind kubectl curl; do
    if command -v "$cmd" &>/dev/null; then
        echo "  $cmd: $(command -v "$cmd")"
    else
        echo "  $cmd: MISSING"
        ok=false
    fi
done

if [ -d "$PRAXIS_DIR" ]; then echo "  praxis dir: $PRAXIS_DIR"
else echo "  praxis dir: MISSING ($PRAXIS_DIR)"; ok=false; fi

if [ -d "$EPP_DIR" ]; then echo "  epp dir: $EPP_DIR"
else echo "  epp dir: MISSING ($EPP_DIR)"; ok=false; fi

if [ -x "$SIM_BIN" ]; then echo "  simulator: $SIM_BIN"
else echo "  simulator: MISSING ($SIM_BIN)"; ok=false; fi

if [ -f "$LOCAL_SMOKE" ]; then echo "  local smoke: $LOCAL_SMOKE"
else echo "  local smoke: MISSING ($LOCAL_SMOKE)"; ok=false; fi

if [ -f "$KIND_SMOKE" ]; then echo "  kind smoke: $KIND_SMOKE"
else echo "  kind smoke: MISSING ($KIND_SMOKE)"; ok=false; fi

if $ok; then echo ""; echo "All prerequisites OK."
else echo ""; echo "Some prerequisites are missing."; exit 1; fi
