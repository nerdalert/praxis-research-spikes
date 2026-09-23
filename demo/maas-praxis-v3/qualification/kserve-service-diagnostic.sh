#!/usr/bin/env bash
set -euo pipefail
: "${EVIDENCE:?EVIDENCE is required}"
: "${SERVICE_HOST:?SERVICE_HOST is required}"
: "${SERVICE_PORT:?SERVICE_PORT is required}"
: "${DIRECT_PATH:?DIRECT_PATH is required}"
: "${EXTERNAL_PATH:?EXTERNAL_PATH is required}"
pod="kserve-route-diagnostic"
kubectl -n llm-internal delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
kubectl -n llm-internal run "$pod" --image=curlimages/curl:8.10.1 --restart=Never --command -- sleep 300 >/dev/null
kubectl -n llm-internal wait --for=jsonpath='{.status.phase}'=Running pod/"$pod" --timeout=120s
body_publisher='{"model":"publishers/llm-internal/models/facebook/opt-125m","messages":[{"role":"user","content":"qualification"}],"stream":false}'
body_short='{"model":"facebook/opt-125m","messages":[{"role":"user","content":"qualification"}],"stream":false}'
{
  echo "service=${SERVICE_HOST}:${SERVICE_PORT}"
  echo "gateway_match_prefix=${EXTERNAL_PATH}"
  echo "gateway_rewrite=${DIRECT_PATH}"
  for case in direct-publisher direct-short external-publisher external-short; do
    case "$case" in
      direct-publisher) path="$DIRECT_PATH"; body="$body_publisher" ;;
      direct-short) path="$DIRECT_PATH"; body="$body_short" ;;
      external-publisher) path="$EXTERNAL_PATH"; body="$body_publisher" ;;
      external-short) path="$EXTERNAL_PATH"; body="$body_short" ;;
    esac
    status=$(kubectl -n llm-internal exec "$pod" -- curl -sS --max-time 15 -o /tmp/response --write-out '%{http_code}' -H 'Content-Type: application/json' --data "$body" "http://${SERVICE_HOST}:${SERVICE_PORT}${path}" || true)
    size=$(kubectl -n llm-internal exec "$pod" -- wc -c /tmp/response 2>/dev/null | awk 'NR==1 {print $1}' || echo 0)
    echo "case=$case path=$path model=$( [[ "$case" == *short ]] && echo resolved-facebook/opt-125m || echo publisher ) status=$status body_bytes=$size"
  done
} | tee "$EVIDENCE/kserve-service-diagnostic.txt"
kubectl -n llm-internal delete pod "$pod" --wait=false >/dev/null
