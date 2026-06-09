#!/usr/bin/env bash
# 03 wrapper: Kubernetes Go EPP Load-Aware Routing.
# Delegates to the narrated Demo 03 script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/03-kubernetes-go-epp-load-aware-routing/run-kubernetes-load-aware.sh"
