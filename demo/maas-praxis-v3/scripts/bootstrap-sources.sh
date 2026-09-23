#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "usage: $0 OUTPUT_DIR DEMO_DIR" >&2
  exit 2
}
[[ $# -eq 2 ]] || usage
out=$1
demo=$2
mkdir -p "$out"

clone_at() {
  local name=$1 url=$2 sha=$3
  git clone --filter=blob:none --no-checkout "$url" "$out/$name" >/dev/null 2>&1
  git -C "$out/$name" fetch --quiet --depth=1 origin "$sha"
  git -C "$out/$name" checkout --quiet --detach "$sha"
}

# These commits are the source revisions used by the qualification. The
# runtime images remain explicit digest-pinned inputs to run-demo.sh.
clone_at ai https://github.com/nerdalert/ai.git ab6847b3a0ca2e15ac34b80ff858705853e5d012
clone_at ai-gateway-controller https://github.com/opendatahub-io/ai-gateway-controller.git 01f425e247a46e85f33a5f376c25df0eac1b9bbe
clone_at ai-gateway-operator https://github.com/opendatahub-io/ai-gateway-operator.git f5c64f0389a21093f8bc4022655bb14794305ab6
clone_at authorino https://github.com/Kuadrant/authorino.git 1deb43b1454ce55def4731037c293cdc3e61bf58
clone_at gateway-api-inference-extension https://github.com/kubernetes-sigs/gateway-api-inference-extension.git 4e9bfc7833f241663e9a9e9fc0090ef9ae549311
clone_at kserve https://github.com/kserve/kserve.git 771a872af2912c3afc7f157471555da289b5239f
clone_at kuadrant-operator https://github.com/Kuadrant/kuadrant-operator.git 112cd1dbc666a80bfa56ec476bdeede23bdd9a95
clone_at limitador https://github.com/Kuadrant/limitador.git 0984355f8408430f75619d42515888af48347df9
clone_at models-as-a-service https://github.com/opendatahub-io/models-as-a-service.git bdec151e575d5f323d3560bbbe220f9b6586fa3d
clone_at praxis https://github.com/nerdalert/praxis.git c9c2a46898ebd47f58cffde5865f9e976078fa6e
clone_at praxis-extproc https://github.com/opendatahub-io/praxis-extproc.git eda427613d5e6071f3ab11c6a5fed0533fa20b15

curl -fsSL "https://github.com/istio/istio/releases/download/1.29.2/istio-1.29.2-linux-amd64.tar.gz" \
  | tar -xz -C "$out"

cp -a "$demo/qualification" "$out/qualification"
cp -a "$demo/manifests/." "$out/"
mkdir -p "$out/fixtures"
cp -a "$demo/fixtures/authz-bridge" "$out/authz-bridge"
cp -a "$demo/fixtures/provider-fixture" "$out/fixtures/provider-fixture"
chmod +x "$out/qualification/"*.sh

printf 'source_root=%s\n' "$out"
