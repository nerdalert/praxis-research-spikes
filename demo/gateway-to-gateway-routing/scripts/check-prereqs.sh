#!/usr/bin/env bash
set -euo pipefail

# Check that all required tools are available for the G2G E2E demo.

DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Default assumes POC branch checkout as sibling to spike repo
PRAXIS_WORKTREE="${PRAXIS_WORKTREE:-$DEMO_DIR/../../../praxis}"
PRAXIS_BIN="${PRAXIS_BIN:-}"

ok=true

check() {
    if command -v "$1" &>/dev/null; then
        printf "  %-20s %s\n" "$1" "$(command -v "$1")"
    else
        printf "  %-20s MISSING\n" "$1"
        ok=false
    fi
}

echo "Checking required tools:"
check openssl
check python3
check curl

echo ""
echo "Checking Praxis binary:"
if [ -n "$PRAXIS_BIN" ] && [ -x "$PRAXIS_BIN" ]; then
    printf "  %-20s %s\n" "praxis" "$PRAXIS_BIN"
elif [ -x "$PRAXIS_WORKTREE/target/debug/praxis" ]; then
    printf "  %-20s %s\n" "praxis" "$PRAXIS_WORKTREE/target/debug/praxis"
elif [ -x "$PRAXIS_WORKTREE/target/release/praxis" ]; then
    printf "  %-20s %s\n" "praxis" "$PRAXIS_WORKTREE/target/release/praxis"
else
    printf "  %-20s MISSING (build from nerdalert/praxis@praxis-multi-cluster-poc-v1)\n" "praxis"
    ok=false
fi

echo ""
echo "Checking demo directory:"
for f in configs/site-a.yaml configs/site-b.yaml configs/site-c.yaml \
         mocks/inference.py mocks/mcp.py mocks/a2a.py; do
    if [ -f "$DEMO_DIR/$f" ]; then
        printf "  %-40s OK\n" "$f"
    else
        printf "  %-40s MISSING\n" "$f"
        ok=false
    fi
done

echo ""
if $ok; then
    echo "All prerequisites satisfied."
else
    echo "Some prerequisites are missing. See above."
    exit 1
fi
