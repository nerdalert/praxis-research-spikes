#!/usr/bin/env bash
set -euo pipefail

# Kill all G2G E2E demo processes.

DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PID_DIR="$DEMO_DIR/.pids"

if [ ! -d "$PID_DIR" ]; then
    echo "No PID directory found — nothing to clean up."
    exit 0
fi

echo "Stopping demo processes..."
for pidfile in "$PID_DIR"/*.pid; do
    [ -f "$pidfile" ] || continue
    name="$(basename "$pidfile" .pid)"
    pid="$(cat "$pidfile")"
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        printf "  %-30s stopped (pid %s)\n" "$name" "$pid"
    else
        printf "  %-30s already gone (pid %s)\n" "$name" "$pid"
    fi
done

sleep 0.5

for pidfile in "$PID_DIR"/*.pid; do
    [ -f "$pidfile" ] || continue
    pid="$(cat "$pidfile")"
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi
done

rm -rf "$PID_DIR"
echo "Cleanup complete."
