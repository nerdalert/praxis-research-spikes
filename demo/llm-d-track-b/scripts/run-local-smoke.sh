#!/usr/bin/env bash
# Track B local smoke: Praxis -> Go EPP -> simulator.
# Delegates to the implementation tree's smoke script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=demo/llm-d-track-b/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

echo "=== Track B Local Smoke ==="
echo "Delegating to: $LOCAL_SMOKE"
echo ""

cd "$TRACK_B_DIR"
exec bash "$LOCAL_SMOKE"
