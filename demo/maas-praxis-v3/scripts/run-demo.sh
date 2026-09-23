#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "usage: $0 --run-id ID --praxis-ai-image NAME@sha256:DIGEST --authz-bridge-image NAME@sha256:DIGEST --evidence-dir DIR [--retain-on-failure]" >&2
  exit 2
}

run_id=""
image=""
authz_image=""
evidence_dir=""
retain=false
while (($#)); do
  case "$1" in
    --run-id) [[ $# -ge 2 ]] || usage; run_id=$2; shift 2 ;;
    --praxis-ai-image) [[ $# -ge 2 ]] || usage; image=$2; shift 2 ;;
    --authz-bridge-image) [[ $# -ge 2 ]] || usage; authz_image=$2; shift 2 ;;
    --evidence-dir) [[ $# -ge 2 ]] || usage; evidence_dir=$2; shift 2 ;;
    --retain-on-failure) retain=true; shift ;;
    *) usage ;;
  esac
done

[[ "$run_id" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || { echo "invalid --run-id" >&2; exit 2; }
[[ "$image" =~ ^[^@]+@sha256:[0-9a-f]{64}$ ]] || { echo "--praxis-ai-image must be name@sha256:digest" >&2; exit 2; }
[[ "$authz_image" =~ ^[^@]+@sha256:[0-9a-f]{64}$ ]] || { echo "--authz-bridge-image must be name@sha256:digest" >&2; exit 2; }
[[ -n "$evidence_dir" ]] || usage

demo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
poc_root=${POC_E2E_ROOT:-"$demo_root/../../../poc-e2e"}
poc_root=$(cd "$poc_root" && pwd)
[[ -x "$poc_root/qualification/cold-run.sh" ]] || { echo "missing POC provisioner: $poc_root" >&2; exit 2; }

mkdir -p "$evidence_dir"
cluster="maas-praxis-v3-$run_id"
keep=false
[[ "$retain" == true ]] && keep=true

RUN_ID="$run_id" CLUSTER="$cluster" EVIDENCE_ROOT="$evidence_dir" \
  PRAXIS_AI_IMAGE="$image" REQUIRE_PRAXIS_AI_IMAGE=true AUTHZ_BRIDGE_IMAGE="$authz_image" KEEP_CLUSTER="$keep" \
  bash "$poc_root/qualification/cold-run.sh"
