#!/usr/bin/env bash
# Check prerequisites for the AI Grid gateway-to-gateway demo.
set -euo pipefail

PASS=0
FAIL=0
WARN=0

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

warn_check() {
  local label="$1"
  local cmd="$2"
  if eval "$cmd" &>/dev/null; then
    echo "  PASS  $label"
    PASS=$((PASS + 1))
  else
    echo "  WARN  $label (optional — only required for /v1/responses stage)"
    WARN=$((WARN + 1))
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

# Required for all provider and consumer gateway stages.
# Built from: docker build -f ai/Containerfile.composed \
#   --build-arg CARGO_FEATURES=llmd-ext-proc \
#   -t localhost/praxis-ai:llmd-ext-proc .
# (Run from the parent dir containing both ai/ and praxis/ siblings.)
# praxis/ must be a checkout of nerdalert/praxis:ai-grid-g2g-demo-validation.
check "praxis-ai:llmd-ext-proc image" \
  "docker image inspect localhost/praxis-ai:llmd-ext-proc 2>/dev/null || \
   podman image inspect localhost/praxis-ai:llmd-ext-proc 2>/dev/null"

# Required for provider gateways (mock EPP for llm-d ext_proc path).
check "praxis-ai-mock-epp:latest image" \
  "docker image inspect localhost/praxis-ai-mock-epp:latest 2>/dev/null || \
   podman image inspect localhost/praxis-ai-mock-epp:latest 2>/dev/null"

# Optional — only required for Stage 6 (mock-openai /v1/responses validation).
# Built from this Grid repo: docker build -t grid-mock-providers:latest \
#   -f mock-providers/Containerfile .
warn_check "grid-mock-providers:latest image (Stage 6 only)" \
  "docker image inspect grid-mock-providers:latest 2>/dev/null || \
   podman image inspect grid-mock-providers:latest 2>/dev/null"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed, ${WARN} warnings (optional)"
if [ "${FAIL}" -gt 0 ]; then
  echo ""
  echo "Set GRID_REPO to your grid checkout if the default path is wrong."
  echo ""
  echo "Gateway image sources:"
  echo "  localhost/praxis-ai:llmd-ext-proc — built from AI repo using Praxis G2G fork:"
  echo "    git clone -b ai-grid-g2g-demo-validation https://github.com/nerdalert/praxis.git praxis"
  echo "    docker build -f ai/Containerfile.composed --build-arg CARGO_FEATURES=llmd-ext-proc -t localhost/praxis-ai:llmd-ext-proc ."
  echo ""
  echo "  grid-mock-providers:latest — built from Grid repo (optional, Stage 6 only):"
  echo "    docker build -t grid-mock-providers:latest -f mock-providers/Containerfile ."
  exit 1
fi
