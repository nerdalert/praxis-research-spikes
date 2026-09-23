#!/usr/bin/env bash
set -euo pipefail

: "${EVIDENCE:?EVIDENCE is required}"
: "${SIM_KEY:?SIM_KEY is required}"
: "${EXT_KEY:?EXT_KEY is required}"
: "${SIM_KEY_ID:?SIM_KEY_ID is required}"
: "${QUOTA_KEY:?QUOTA_KEY is required}"

tmp=$(mktemp -d)
pf_pid=""
suite_rc=0
on_exit() {
  suite_rc=$?
  if [[ "$suite_rc" != 0 || "$failed" != 0 ]]; then
    {
      echo "service_suite_diagnostics rc=$suite_rc failed=$failed"
      kubectl get pods -A -o wide 2>&1 || true
      kubectl -n models-as-a-service logs deployment/praxis-service-poc --all-containers --tail=500 2>&1 || true
      kubectl -n models-as-a-service logs deployment/praxis-maas-authz --all-containers --tail=500 2>&1 || true
      kubectl -n maas-praxis-system logs deployment/provider-a-fixture --all-containers --tail=500 2>&1 || true
      kubectl -n maas-praxis-system logs deployment/provider-b-fixture --all-containers --tail=500 2>&1 || true
      kubectl -n llm-internal logs deployment/praxis-sim-kserve --all-containers --tail=500 2>&1 || true
    } > "$EVIDENCE/service-suite-diagnostics.txt"
  fi
  [[ -n "$pf_pid" ]] && kill "$pf_pid" 2>/dev/null || true
  rm -rf "$tmp"
  exit "$suite_rc"
}
trap on_exit EXIT
exec > >(tee "$EVIDENCE/service-suite.log") 2>&1
passed=0
failed=0

assert_status() {
  local name=$1 want=$2 got=$3
  if [[ "$want" == "$got" ]]; then
    echo "PASS $name status=$got"
    passed=$((passed + 1))
  else
    echo "FAIL $name expected=$want actual=$got"
    failed=$((failed + 1))
  fi
}

request() {
  local name=$1 key=$2 model=$3 stream=${4:-false}
  local auth=()
  [[ -n "$key" ]] && auth=(-H "Authorization: Bearer $key")
  curl -sS --max-time 20 --no-buffer http://127.0.0.1:18080/v1/chat/completions \
    "${auth[@]}" -H 'Content-Type: application/json' \
    -H 'X-Api-Key: caller-override-must-not-forward' \
    -H 'X-Endpoint-Selection: caller-override-must-not-forward' \
    --data "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"qualification\"}],\"stream\":$stream}" \
    -o "$tmp/$name.body" -w '%{http_code}' > "$tmp/$name.status"
  cat "$tmp/$name.status"
}

kubectl port-forward -n models-as-a-service svc/praxis-service-poc 18080:8080 >"$tmp/port-forward.log" 2>&1 &
pf_pid=$!
for _ in $(seq 1 30); do
  if curl -fsS --max-time 1 http://127.0.0.1:18080/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

assert_status anonymous 401 "$(request anonymous '' 'publishers/llm-internal/models/facebook/opt-125m')"
assert_status invalid-key 403 "$(request invalid 'sk-oai-invalid-qualification-key' 'publishers/llm-internal/models/facebook/opt-125m')"
assert_status authorized-service 200 "$(request authorized-service "$SIM_KEY" 'publishers/llm-internal/models/facebook/opt-125m')"
assert_status authorized-external 200 "$(request authorized-external "$EXT_KEY" praxis-external)"

if kubectl -n maas-praxis-system logs deployment/provider-a-fixture --since=2m 2>/dev/null | grep -q 'credential_valid=true.*caller_api_key_present=false'; then
  echo 'PASS provider-credential-projection'
  passed=$((passed + 1))
else
  echo 'FAIL provider-credential-projection'
  failed=$((failed + 1))
fi

before=$(kubectl -n maas-praxis-system logs deployment/provider-a-fixture --since=2m 2>/dev/null | grep -c provider_contact || true)
assert_status wrong-model 403 "$(request wrong-model "$SIM_KEY" praxis-external)"
after=$(kubectl -n maas-praxis-system logs deployment/provider-a-fixture --since=2m 2>/dev/null | grep -c provider_contact || true)
if [[ "$before" == "$after" ]]; then
  echo 'PASS wrong-model-no-provider-contact'
  passed=$((passed + 1))
else
  echo "FAIL wrong-model-no-provider-contact before=$before after=$after"
  failed=$((failed + 1))
fi

assert_status streaming 200 "$(request streaming "$SIM_KEY" 'publishers/llm-internal/models/facebook/opt-125m' true)"
if grep -q 'data:' "$tmp/streaming.body"; then
  echo 'PASS streaming-body'
  passed=$((passed + 1))
else
  echo 'FAIL streaming-body'
  failed=$((failed + 1))
fi

kubectl -n models-as-a-service delete externalmodel praxis-external --wait=false >/dev/null
for _ in $(seq 1 60); do
  if ! kubectl -n models-as-a-service get externalmodel praxis-external >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
assert_status service-after-external-delete 200 "$(request service-after-external-delete "$SIM_KEY" 'publishers/llm-internal/models/facebook/opt-125m')"

revoke_status=$(kubectl exec -n maas-praxis-system deployment/maas-api -- curl -sk -o /dev/null -w '%{http_code}' -X DELETE \
  "https://localhost:8443/v1/api-keys/$SIM_KEY_ID" \
  -H 'X-MaaS-Username: qualification-sim' \
  -H 'X-MaaS-Group: ["system:authenticated"]')
if [[ "$revoke_status" != 200 && "$revoke_status" != 204 ]]; then
  echo "FAIL revoke-api status=$revoke_status"
  failed=$((failed + 1))
else
  echo "PASS revoke-api status=$revoke_status"
  passed=$((passed + 1))
fi
revoked_status=200
for _ in $(seq 1 90); do
  revoked_status="$(request revoked "$SIM_KEY" 'publishers/llm-internal/models/facebook/opt-125m')"
  [[ "$revoked_status" == 401 ]] && break
  sleep 1
done
if [[ "$revoked_status" == 401 || "$revoked_status" == 403 ]]; then
  echo "PASS revoked-key status=$revoked_status"
  passed=$((passed + 1))
else
  echo "FAIL revoked-key expected=401-or-403 actual=$revoked_status"
  failed=$((failed + 1))
fi

# Exhaust the actual MaaS-generated Limitador bucket for the independent quota
# subject. This avoids changing generated policy during the test and keeps
# revocation, streaming, and quota assertions from masking one another.
quota_first=0
quota_last=0
quota_bad=0
for attempt in $(seq 1 101); do
  quota_status="$(request quota-$attempt "$QUOTA_KEY" 'publishers/llm-internal/models/facebook/opt-125m')"
  if [[ "$attempt" -eq 1 ]]; then quota_first="$quota_status"; fi
  if [[ "$attempt" -lt 101 && "$quota_status" != 200 ]]; then quota_bad=$((quota_bad + 1)); fi
  if [[ "$attempt" -eq 101 ]]; then quota_last="$quota_status"; fi
done
if [[ "$quota_bad" == 0 ]]; then
  echo "PASS quota-first status=$quota_first"
  passed=$((passed + 1))
else
  echo "FAIL quota-first unexpected_denials=$quota_bad first=$quota_first"
  failed=$((failed + 1))
fi
assert_status quota-shared 429 "$quota_last"

cat > "$EVIDENCE/service-suite-summary.json" <<EOF
{"passed":$passed,"failed":$failed,"path":"client->Praxis->Authorino->Limitador->KServe Service"}
EOF
(( failed == 0 ))
