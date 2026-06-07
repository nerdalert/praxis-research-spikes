#!/usr/bin/env bash
# Clean up Track B KIND cluster.
# Delegates to the implementation tree's cleanup script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=demo/llm-d-track-b/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

echo "=== Track B KIND Cleanup ==="
exec bash "$KIND_CLEANUP"
