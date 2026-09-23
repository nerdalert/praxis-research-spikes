#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${1:-}" == "--run-id" && -n "${2:-}" ]] || {
  echo "usage: $0 --run-id ID" >&2
  exit 2
}
run_id=$2
[[ "$run_id" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || { echo "invalid --run-id" >&2; exit 2; }
cluster="maas-praxis-v3-$run_id"
if kind get clusters 2>/dev/null | grep -Fxq "$cluster"; then
  kind delete cluster --name "$cluster"
else
  echo "cluster absent: $cluster"
fi
