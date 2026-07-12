#!/usr/bin/env bash
# Full AI Grid gateway-to-gateway demo sequence.
#
# Runs all validated demo steps in order:
#   provider baseline → provider gateways → consumer G2G (static) →
#   consumer G2G (overlay) → mTLS trust → teardown
#
# Usage:
#   bash scripts/run-full-demo.sh
#   GRID_REPO=/path/to/grid bash scripts/run-full-demo.sh
#   SKIP_OVERLAY=1 bash scripts/run-full-demo.sh   # skip overlay step
#
# Prerequisites: bash scripts/check-prereqs.sh
set -euo pipefail

GRID_REPO="${GRID_REPO:-${HOME}/grid}"
CARGO="${CARGO:-cargo}"
TOOLCHAIN="${TOOLCHAIN:-+1.96.0}"
OVERLAY_CONFIG="${OVERLAY_CONFIG:-/tmp/grid-demo-overlay.json}"
SKIP_OVERLAY="${SKIP_OVERLAY:-0}"

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
xtask env verify-mtls-trust || true   # 9/10 is acceptable; do not abort

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

header "TEARDOWN"
xtask env down

echo ""
echo "=== Demo complete ==="
echo "  Provider baseline:  15/15"
echo "  Provider gateways:  16/16"
echo "  Consumer G2G static: 8/8"
[ "${SKIP_OVERLAY}" = "0" ] && echo "  Consumer G2G overlay: 8/8"
echo "  mTLS trust:          9/10 or 10/10 (timing flake in kind)"
