#!/usr/bin/env bash
# 01 wrapper: Praxis-to-Go-EPP request path.
# Delegates to the implementation tree's request-path validation script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=demo/llm-d-track-b/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

echo "=== Track B: Praxis-to-Go-EPP Request Path ==="
echo "Delegating to: $REQUEST_PATH_SCRIPT"
echo ""

cd "$TRACK_B_DIR"
exec bash "$REQUEST_PATH_SCRIPT"
