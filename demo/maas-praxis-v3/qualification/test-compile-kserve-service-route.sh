#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$ROOT/qualification/compile-kserve-service-route.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/multiple-families.json" <<'EOF'
{"metadata":{"namespace":"llm-internal"},"spec":{"rules":[
  {"matches":[{"path":{"value":"/unrelated/v1/chat/completions"}}],"filters":[{"urlRewrite":{"path":{"replacePrefixMatch":"/wrong"}}}],"backendRefs":[{"name":"other","port":8000}]},
  {"matches":[{"path":{"value":"/llm-internal/second-model/v1/chat/completions"}}],"filters":[{"urlRewrite":{"path":{"replacePrefixMatch":"/v1/chat/completions"}}}],"backendRefs":[{"name":"second-model-kserve-workload-svc","port":8000}]}
]}}
EOF
result=$($compiler "$tmp/multiple-families.json" second-model-kserve-workload-svc 8000 llm-internal)
jq -e '.backendRef.name == "second-model-kserve-workload-svc" and .backendRef.namespace == "llm-internal" and .clientPrefix == "/llm-internal/second-model" and .backendRewrite == "/v1/chat/completions"' <<<"$result" >/dev/null
if $compiler "$tmp/multiple-families.json" missing 8000 llm-internal >/dev/null 2>&1; then exit 1; fi
cat > "$tmp/ambiguous.json" <<'EOF'
{"metadata":{"namespace":"llm-internal"},"spec":{"rules":[
  {"matches":[{"path":{"value":"/a/v1/chat/completions"}}],"filters":[{"urlRewrite":{"path":{"replacePrefixMatch":"/v1/chat/completions"}}}],"backendRefs":[{"name":"same","port":8000}]},
  {"matches":[{"path":{"value":"/b/v1/chat/completions"}}],"filters":[{"urlRewrite":{"path":{"replacePrefixMatch":"/v1/chat/completions"}}}],"backendRefs":[{"name":"same","port":8000}]}
]}}
EOF
if $compiler "$tmp/ambiguous.json" same 8000 llm-internal >/dev/null 2>&1; then exit 1; fi
echo 'PASS compile-kserve-service-route'
