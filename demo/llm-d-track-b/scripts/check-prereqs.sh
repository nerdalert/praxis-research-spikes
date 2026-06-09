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

if [ -x "$PRAXIS_BIN" ]; then echo "  praxis binary: $PRAXIS_BIN"
else echo "  praxis binary: MISSING ($PRAXIS_BIN)"; ok=false; fi

if [ -x "$EPP_BIN" ]; then echo "  epp binary: $EPP_BIN"
else echo "  epp binary: MISSING ($EPP_BIN)"; ok=false; fi

if [ -x "$SIM_BIN" ]; then echo "  simulator binary: $SIM_BIN"
else echo "  simulator binary: MISSING ($SIM_BIN)"; ok=false; fi

if [ -d "$CONFIGS_DIR" ]; then echo "  demo configs: $CONFIGS_DIR"
else echo "  demo configs: MISSING ($CONFIGS_DIR)"; ok=false; fi

if $ok; then echo ""; echo "All prerequisites OK."
else echo ""; echo "Some prerequisites are missing."; exit 1; fi
