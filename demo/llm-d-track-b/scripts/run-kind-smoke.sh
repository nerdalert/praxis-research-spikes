#!/usr/bin/env bash
# Track B KIND smoke: Praxis -> Go EPP -> simulator in Kubernetes.
# Delegates to the implementation tree's KIND smoke script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=demo/llm-d-track-b/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

echo "=== Track B KIND Smoke ==="
echo "Delegating to: $KIND_SMOKE"
echo ""

cd "$TRACK_B_DIR"
exec bash "$KIND_SMOKE"
