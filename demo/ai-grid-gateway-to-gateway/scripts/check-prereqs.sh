#!/usr/bin/env bash
# Check prerequisites for the AI Grid gateway-to-gateway demo.
set -euo pipefail

PASS=0
FAIL=0

check() {
  local label="$1"
  local cmd="$2"
  if eval "$cmd" &>/dev/null; then
    echo "  PASS  $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $label"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== AI Grid demo prerequisites ==="

check "kind is installed"          "command -v kind"
check "kubectl is installed"       "command -v kubectl"
check "docker is installed"        "command -v docker || command -v podman"
check "curl is installed"          "command -v curl"
check "Rust 1.96.0 toolchain"      "rustup show active-toolchain | grep -q 1.96 || cargo +1.96.0 --version"

GRID_REPO="${GRID_REPO:-${HOME}/grid}"
check "Grid repo exists at GRID_REPO" "test -d '${GRID_REPO}/xtask'"

check "praxis-ai:llmd-ext-proc image" \
  "docker image inspect localhost/praxis-ai:llmd-ext-proc 2>/dev/null || \
   podman image inspect localhost/praxis-ai:llmd-ext-proc 2>/dev/null"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -gt 0 ]; then
  echo ""
  echo "Set GRID_REPO to your grid checkout if the default path is wrong."
  echo "Build the praxis-ai image with: cargo xtask env build-gateway-images --ai-repo <path>"
  exit 1
fi
