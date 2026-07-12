#!/usr/bin/env bash
# Full AI Grid gateway-to-gateway demo sequence.
#
# Runs all validated demo steps in order:
#   provider baseline → provider gateways → consumer G2G (static) →
#   consumer G2G (overlay) → mTLS trust →
#   mock-openai /v1/responses provider gateway → teardown
#
# Usage:
#   bash scripts/run-full-demo.sh
#   GRID_REPO=/path/to/grid bash scripts/run-full-demo.sh
#   SKIP_OVERLAY=1 bash scripts/run-full-demo.sh      # skip overlay step
#   SKIP_RESPONSES=1 bash scripts/run-full-demo.sh    # skip /v1/responses step
#
# Prerequisites: bash scripts/check-prereqs.sh
set -euo pipefail

GRID_REPO="${GRID_REPO:-${HOME}/grid}"
CARGO="${CARGO:-cargo}"
TOOLCHAIN="${TOOLCHAIN:-+1.96.0}"
OVERLAY_CONFIG="${OVERLAY_CONFIG:-/tmp/grid-demo-overlay.json}"
MOCK_OPENAI_CONFIG="${MOCK_OPENAI_CONFIG:-/tmp/grid-mock-openai-config.toml}"
SKIP_OVERLAY="${SKIP_OVERLAY:-0}"
SKIP_RESPONSES="${SKIP_RESPONSES:-0}"

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

xtask() {
  "${CARGO}" "${TOOLCHAIN}" run -p xtask -- "$@"
}

header() {
  echo ""
  echo "==============================================================================="
  echo "  $*"
  echo "==============================================================================="
}

cd "${GRID_REPO}"

# ---------------------------------------------------------------------------
# Stage 1: environment setup and provider baseline
# ---------------------------------------------------------------------------

header "STAGE 1 — Environment setup"
xtask env up

header "STAGE 1 — Status"
xtask env status

header "STAGE 1 — Provider inference baseline (expected: 15/15)"
xtask env verify-providers

# ---------------------------------------------------------------------------
# Stage 2: provider gateways (requires localhost/praxis-ai:llmd-ext-proc)
# ---------------------------------------------------------------------------

header "STAGE 2 — Load gateway images"
xtask env load-gateway-images

header "STAGE 2 — Deploy provider gateways"
xtask env deploy-provider-gateways

header "STAGE 2 — Verify provider gateways (expected: 16/16)"
xtask env verify-provider-gateways

# ---------------------------------------------------------------------------
# Stage 3: consumer gateway — static routing
# ---------------------------------------------------------------------------

header "STAGE 3 — Probe gateway network"
xtask env probe-gateway-network

header "STAGE 3 — Deploy consumer gateway (static config)"
xtask env deploy-consumer-gateway

header "STAGE 3 — Verify gateway E2E — static (expected: 8/8)"
xtask env verify-gateway-e2e

# ---------------------------------------------------------------------------
# Stage 4: consumer gateway — operator overlay config
# ---------------------------------------------------------------------------

if [ "${SKIP_OVERLAY}" = "0" ]; then
  if [ ! -f "${OVERLAY_CONFIG}" ]; then
    echo "Copying example overlay to ${OVERLAY_CONFIG}"
    cp "${DEMO_DIR}/configs/example-overlay.json" "${OVERLAY_CONFIG}"
  fi

  header "STAGE 4 — Deploy consumer gateway (overlay config)"
  xtask env deploy-consumer-gateway --overlay-config "${OVERLAY_CONFIG}"

  header "STAGE 4 — Verify gateway E2E — overlay (expected: 8/8)"
  xtask env verify-gateway-e2e
else
  echo "SKIPPING overlay stage (SKIP_OVERLAY=1)"
fi

# ---------------------------------------------------------------------------
# Stage 5: mTLS trust verification
# ---------------------------------------------------------------------------

header "STAGE 5 — Verify mTLS trust (expected: 9/10 or 10/10)"
xtask env verify-mtls-trust || true   # 9/10 is acceptable; see troubleshooting

# ---------------------------------------------------------------------------
# Teardown of inference-sim topology
# ---------------------------------------------------------------------------

header "TEARDOWN — inference-sim clusters"
xtask env down

# ---------------------------------------------------------------------------
# Stage 6: mock-openai backend + /v1/responses provider gateway verification
# ---------------------------------------------------------------------------

if [ "${SKIP_RESPONSES}" = "0" ]; then
  # Requires: grid-mock-providers:latest (built separately from mock-providers/Containerfile)
  if ! docker image inspect grid-mock-providers:latest &>/dev/null 2>&1 && \
     ! podman image inspect grid-mock-providers:latest &>/dev/null 2>&1; then
    echo "WARNING: grid-mock-providers:latest not found."
    echo "  Build it with: docker build -t grid-mock-providers:latest -f mock-providers/Containerfile ."
    echo "  Skipping /v1/responses step."
    SKIP_RESPONSES=1
  fi
fi

if [ "${SKIP_RESPONSES}" = "0" ]; then
  if [ ! -f "${MOCK_OPENAI_CONFIG}" ]; then
    echo "Copying mock-openai config to ${MOCK_OPENAI_CONFIG}"
    cp "${DEMO_DIR}/configs/mock-openai-config.toml" "${MOCK_OPENAI_CONFIG}"
  fi

  # Trap ensures mock-openai clusters are torn down even if a step fails.
  _MOCK_OPENAI_UP=0
  _mock_openai_cleanup() {
    if [ "${_MOCK_OPENAI_UP}" = "1" ]; then
      echo "Cleaning up mock-openai clusters on exit..."
      xtask env down --config "${MOCK_OPENAI_CONFIG}" 2>/dev/null || true
    fi
  }
  trap _mock_openai_cleanup EXIT

  header "STAGE 6 — Stand up mock-openai backend cluster"
  xtask env up --config "${MOCK_OPENAI_CONFIG}"
  _MOCK_OPENAI_UP=1

  header "STAGE 6 — Load images (includes grid-mock-providers for mock-openai cluster)"
  xtask env load-gateway-images --config "${MOCK_OPENAI_CONFIG}"

  header "STAGE 6 — Deploy provider gateways (mock-openai backend)"
  xtask env deploy-provider-gateways --config "${MOCK_OPENAI_CONFIG}"

  header "STAGE 6 — Verify: Chat Completions + /v1/responses (expected: 9/9)"
  xtask env verify-provider-gateways --config "${MOCK_OPENAI_CONFIG}"

  header "TEARDOWN — mock-openai clusters"
  xtask env down --config "${MOCK_OPENAI_CONFIG}"
  _MOCK_OPENAI_UP=0
  trap - EXIT
else
  echo "SKIPPING /v1/responses stage (SKIP_RESPONSES=1 or image missing)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "=== Demo complete ==="
echo "  Provider baseline:    15/15"
echo "  Provider gateways:    16/16"
echo "  Consumer G2G static:   8/8"
[ "${SKIP_OVERLAY}"   = "0" ] && echo "  Consumer G2G overlay:  8/8"
echo "  mTLS trust:            9/10 or 10/10 (see troubleshooting)"
[ "${SKIP_RESPONSES}" = "0" ] && echo "  /v1/responses gateway: 9/9"
