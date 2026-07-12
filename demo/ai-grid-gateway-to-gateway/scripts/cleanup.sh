#!/usr/bin/env bash
# Tear down the AI Grid demo environment.
# Safe to run even if env up was not completed.
set -euo pipefail

GRID_REPO="${GRID_REPO:-${HOME}/grid}"
CARGO="${CARGO:-cargo}"
TOOLCHAIN="${TOOLCHAIN:-+1.96.0}"

echo "=== AI Grid demo cleanup ==="
cd "${GRID_REPO}"

"${CARGO}" "${TOOLCHAIN}" run -p xtask -- env down 2>&1 || true

echo ""
echo "Checking for leftover kind clusters..."
kind get clusters 2>/dev/null | grep "^grid-cluster-" && \
  echo "WARNING: grid-cluster-* clusters still present. Run: kind delete cluster --name <name>" || \
  echo "  clean — no grid-cluster-* clusters"

echo ""
echo "Checking for leftover port-forwards..."
pgrep -af 'kubectl.*port-forward' | grep -v grep && \
  echo "WARNING: port-forward processes found. Kill with: pkill -f 'kubectl.*port-forward'" || \
  echo "  clean — no port-forward processes"
