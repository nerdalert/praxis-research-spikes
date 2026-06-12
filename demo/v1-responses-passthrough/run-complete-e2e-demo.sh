#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$SCRIPT_DIR/integration-test-output.md}"

echo "Generating complete /v1/responses passthrough transcript ..."
bash "$SCRIPT_DIR/scripts/run-smoke.sh" "$OUT"
echo "Transcript written to: $OUT"
