#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "usage: $0 --run-id ID --praxis-ai-image NAME@sha256:DIGEST --authz-bridge-image NAME@sha256:DIGEST [--provider-fixture-image NAME@sha256:DIGEST --controller-image NAME@sha256:DIGEST | --build-local-fixtures] --evidence-dir DIR [--retain-on-failure]" >&2
  exit 2
}

run_id=""
image=""
authz_image=""
provider_image=""
controller_image=""
evidence_dir=""
retain=false
build_local=false
while (($#)); do
  case "$1" in
    --run-id) [[ $# -ge 2 ]] || usage; run_id=$2; shift 2 ;;
    --praxis-ai-image) [[ $# -ge 2 ]] || usage; image=$2; shift 2 ;;
    --authz-bridge-image) [[ $# -ge 2 ]] || usage; authz_image=$2; shift 2 ;;
    --provider-fixture-image) [[ $# -ge 2 ]] || usage; provider_image=$2; shift 2 ;;
    --controller-image) [[ $# -ge 2 ]] || usage; controller_image=$2; shift 2 ;;
    --evidence-dir) [[ $# -ge 2 ]] || usage; evidence_dir=$2; shift 2 ;;
    --retain-on-failure) retain=true; shift ;;
    --build-local-fixtures) build_local=true; shift ;;
    *) usage ;;
  esac
done

[[ "$run_id" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || { echo "invalid --run-id" >&2; exit 2; }
[[ "$image" =~ ^[^@]+@sha256:[0-9a-f]{64}$ ]] || { echo "--praxis-ai-image must be name@sha256:digest" >&2; exit 2; }
[[ "$authz_image" =~ ^[^@]+@sha256:[0-9a-f]{64}$ ]] || { echo "--authz-bridge-image must be name@sha256:digest" >&2; exit 2; }
if [[ "$build_local" == true ]]; then
  [[ -z "$provider_image" && -z "$controller_image" ]] || { echo "do not combine --build-local-fixtures with fixture image inputs" >&2; exit 2; }
else
  [[ "$provider_image" =~ ^[^@]+@sha256:[0-9a-f]{64}$ ]] || { echo "--provider-fixture-image must be name@sha256:digest" >&2; exit 2; }
  [[ "$controller_image" =~ ^[^@]+@sha256:[0-9a-f]{64}$ ]] || { echo "--controller-image must be name@sha256:digest" >&2; exit 2; }
fi
[[ -n "$evidence_dir" ]] || usage

demo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work_root=$(mktemp -d "${TMPDIR:-/tmp}/maas-praxis-v3.XXXXXX")
trap 'find "$work_root" -type f -delete 2>/dev/null || true; find "$work_root" -type d -depth -empty -delete 2>/dev/null || true' EXIT
"$demo_root/scripts/bootstrap-sources.sh" "$work_root" "$demo_root"
[[ -x "$work_root/qualification/cold-run.sh" ]] || { echo "bootstrap did not provide the provisioner" >&2; exit 2; }

mkdir -p "$evidence_dir"
cluster="maas-praxis-v3-$run_id"
keep=false
[[ "$retain" == true ]] && keep=true

RUN_ID="$run_id" CLUSTER="$cluster" EVIDENCE_ROOT="$evidence_dir" \
  PRAXIS_AI_IMAGE="$image" REQUIRE_PRAXIS_AI_IMAGE=true AUTHZ_BRIDGE_IMAGE="$authz_image" \
  PROVIDER_FIXTURE_IMAGE="$provider_image" AI_GATEWAY_CONTROLLER_IMAGE="$controller_image" KEEP_CLUSTER="$keep" \
  bash "$work_root/qualification/cold-run.sh"
