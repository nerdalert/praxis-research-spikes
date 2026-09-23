#!/usr/bin/env bash
set -Eeuo pipefail

# Run-owned compatibility compiler.  It watches the current MaaS-generated
# objects through kubectl and publishes one ConfigMap containing both policy
# and provider routing state.  It deliberately does not decide entitlement;
# Authorino and Limitador remain authoritative.  The production ownership
# boundary for this logic is the AI Gateway controller; this harness makes the
# missing writer explicit and reproducible while that product work is pending.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NAMESPACE=${NAMESPACE:-models-as-a-service}
SNAPSHOT_CONFIGMAP=${SNAPSHOT_CONFIGMAP:-praxis-runtime-snapshot}
INTERVAL=${INTERVAL:-2}
OUT_DIR=${OUT_DIR:-$(mktemp -d)}
mkdir -p "$OUT_DIR"
trap 'rm -rf "$OUT_DIR"' EXIT

log() { printf 'runtime-reconciler %s\n' "$*"; }

render_policy() {
  local models="$OUT_DIR/models.json" routes="$OUT_DIR/routes.json" limits="$OUT_DIR/limits.json" auth="$OUT_DIR/auth.json" pools="$OUT_DIR/pools.json"
  kubectl get maasmodelref -A -o json > "$models"
  kubectl get httproute -A -o json > "$routes"
  kubectl -n kuadrant-system get limitador limitador -o json > "$limits"
  kubectl -n kuadrant-system get authconfig -o json > "$auth"
  # The Service-backed qualification deliberately does not require the
  # InferencePool CRD. Treat its absence as an empty pool set so a later EPP
  # milestone remains optional rather than a prerequisite for Service routes.
  kubectl get inferencepool -A -o json > "$pools" 2>/dev/null || printf '{"items":[]}' > "$pools"

  : > "$OUT_DIR/items.jsonl"
  local total_models ready_models
  total_models=$(jq '.items | length' "$models")
  ready_models=$(jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' "$models")
  if [[ "$ready_models" != "$total_models" ]]; then
    log "policy sources not all Ready ready=$ready_models total=$total_models; retain last complete revision"
    return 1
  fi
  while IFS= read -r model; do
    local model_ns model_name model_kind client_model route_ns route_name route_json rule_index annotation host_scope domain descriptor_key backend
    model_ns=$(jq -r '.metadata.namespace' <<<"$model")
    model_name=$(jq -r '.metadata.name' <<<"$model")
    model_kind=$(jq -r '.spec.modelRef.kind' <<<"$model")
    # The request model is MaaS's resolved client-visible alias, not the
    # storage identity of the MaaSModelRef.  KServe aliases are typically
    # publishers/<namespace>/models/<model>; ExternalModel aliases are the
    # ExternalModel modelName.  Falling back to namespace/name is fail-closed
    # compatibility for incomplete fixtures only.
    client_model=$(jq -r '.status.resolvedModelAlias // empty' <<<"$model")
    [[ -n "$client_model" ]] || client_model="$model_ns/$model_name"
    backend="external"
    if [[ "$model_kind" == "LLMInferenceService" ]]; then
      backend="service"
      if jq -e --arg ns "$model_ns" --arg name "$model_name" '[.items[] | select(.metadata.namespace == $ns) | any(.metadata.ownerReferences[]?; .kind == "LLMInferenceService" and .name == $name)] | any' "$pools" >/dev/null; then
        backend="epp"
      fi
    fi
    route_ns=$(jq -r '.status.httpRouteNamespace // empty' <<<"$model")
    route_name=$(jq -r '.status.httpRouteName // empty' <<<"$model")
    [[ -n "$route_ns" && -n "$route_name" ]] || { log "skip model=${model_ns}/${model_name} missing Ready route"; continue; }
    route_json=$(jq -c --arg ns "$route_ns" --arg name "$route_name" '.items[] | select(.metadata.namespace==$ns and .metadata.name==$name)' "$routes")
    [[ -n "$route_json" ]] || { log "skip model=${model_ns}/${model_name} missing route=${route_ns}/${route_name}"; continue; }
    if [[ "$model_kind" == "ExternalModel" ]]; then
      rule_index=$(jq -r '[.spec.rules | to_entries[] | select((.value.matches[0].path.value // "") == "/") | select(any(.value.matches[0].headers[]?; (.name | ascii_downcase) == "x-gateway-model-name")) | select(all(.value.matches[0].headers[]?; (.name | ascii_downcase) != "x-ipp-selected-provider"))] | .[0].key // empty' <<<"$route_json")
    else
      rule_index=$(jq -r '[.spec.rules | to_entries[] | select((.value.matches[0].path.value // "") | endswith("/v1/chat/completions"))] | .[0].key // empty' <<<"$route_json")
    fi
    [[ -n "$rule_index" ]] || { log "skip model=${model_ns}/${model_name} no supported chat rule"; continue; }
    annotation="httproute.gateway.networking.k8s.io:${route_ns}/${route_name}#rule-$((rule_index + 1))"
    host_scope=$(jq -r --arg annotation "$annotation" '[.items[] | select(.metadata.annotations["HTTPRouteRule.gateway.networking.k8s.io"] == $annotation) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty' "$auth")
    domain_candidates=("${route_ns}/${route_name}" "$route_name")
    domain=""
    for candidate_domain in "${domain_candidates[@]}"; do
      if jq -e --arg d "$candidate_domain" '.spec.limits[]? | select(.namespace == $d)' "$limits" >/dev/null; then domain="$candidate_domain"; break; fi
    done
    descriptor_key=$(jq -r --arg d "$domain" '.spec.limits[] | select(.namespace == $d) | .conditions[0] | capture("descriptors\\[0\\]\\[\\\"(?<k>[^\\\"]+)\\\"\\]") | .k' "$limits" | head -1)
    [[ -n "$host_scope" && -n "$domain" && -n "$descriptor_key" ]] || { log "fail closed model=${model_ns}/${model_name} route=${route_ns}/${route_name} policy_not_ready"; return 1; }
    jq -cn --arg name "$model_name" --arg model "$client_model" --arg backend "$backend" --arg scope "$host_scope" --arg domain "$domain" --arg key "$descriptor_key" '{name:$name,model:$model,backend:$backend,authorino_host_scope:$scope,limitador_domain:$domain,descriptor_key:$key,descriptor_value:"1"}' >> "$OUT_DIR/items.jsonl"
  done < <(jq -c '.items[]' "$models")

  local rendered_models
  rendered_models=$(wc -l < "$OUT_DIR/items.jsonl")
  if [[ "$rendered_models" != "$total_models" ]]; then
    log "policy sources incomplete rendered=$rendered_models total=$total_models; retain last complete revision"
    return 1
  fi

  # An empty generated route set is a valid fail-closed revision. Publish it
  # when the final model/provider disappears; retaining the prior snapshot
  # would keep revoked or deleted serving state active.
  jq -s '{routes: .}' "$OUT_DIR/items.jsonl" > "$OUT_DIR/policy.json"
}

publish() {
  render_policy
  local external_ref external_namespace external_model
  external_ref=$(kubectl get maasmodelref -A -o json | jq -r '[.items[] | select(.spec.modelRef.kind == "ExternalModel") | [.metadata.namespace,.spec.modelRef.name] | @tsv] | if length == 1 then .[0] else empty end')
  if [[ -z "$external_ref" ]]; then
    "$ROOT/qualification/render-external-overlay.sh" "$NAMESPACE" "" "$OUT_DIR/routing-overlay.json"
  else
    external_namespace=${external_ref%%$'\t'*}
    external_model=${external_ref#*$'\t'}
    "$ROOT/qualification/render-external-overlay.sh" "$external_namespace" "$external_model" "$OUT_DIR/routing-overlay.json"
  fi
  local revision
  revision=$(jq -r '.revision.value // empty' "$OUT_DIR/routing-overlay.json")
  [[ -n "$revision" ]] || { log "overlay has no content revision"; return 1; }
  local policy_revision
  policy_revision=$(jq -cS --arg overlay_revision "$revision" '{overlay_revision:$overlay_revision, policy:.}' "$OUT_DIR/policy.json" | sha256sum | awk '{print $1}')
  jq --arg revision "$policy_revision" --arg overlay_revision "$revision" '.revision=$revision | .overlay_revision=$overlay_revision' "$OUT_DIR/policy.json" > "$OUT_DIR/policy.revision.json"
  kubectl -n "$NAMESPACE" create configmap "$SNAPSHOT_CONFIGMAP" \
    --from-file=policy.json="$OUT_DIR/policy.revision.json" \
    --from-file=routing-overlay.json="$OUT_DIR/routing-overlay.json" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # Temporary POC bridge: the controller waits for this ConfigMap before it
  # can publish the ExternalModel HTTPRoute, while the route is needed before
  # the controller can mark the MaaS model Ready. Product code must replace
  # this writer with one controller-owned coherent revision.
  kubectl -n "$NAMESPACE" create configmap routing-overlay \
    --from-file=routing-overlay.json="$OUT_DIR/routing-overlay.json" \
    --dry-run=client -o yaml |
    kubectl label --local -f - app.kubernetes.io/managed-by=ai-gateway-controller -o yaml |
    kubectl apply -f - >/dev/null
  log "published revision=$policy_revision overlay_revision=$revision routes=$(jq '.routes|length' "$OUT_DIR/policy.revision.json")"
}

last_fingerprint=""
while true; do
  # Provider readiness and credential metadata are part of the serving
  # revision.  Include them in the trigger so an initially empty/fail-closed
  # overlay is republished when cold provisioning finishes ExternalProvider
  # reconciliation or rotates/deletes a referenced Secret.
  fingerprint=$({ kubectl get maasmodelref -A -o json; kubectl get httproute -A -o json; kubectl -n kuadrant-system get authconfig -o json; kubectl -n kuadrant-system get limitador limitador -o json; kubectl get externalmodel -A -o json; kubectl get externalprovider -A -o json; kubectl get secret -A -o json; } 2>/dev/null | sha256sum | awk '{print $1}') || true
  if [[ -n "$fingerprint" && "$fingerprint" != "$last_fingerprint" ]]; then
    if publish; then last_fingerprint="$fingerprint"; else log "publish failed; retaining previous snapshot"; fi
  fi
  sleep "$INTERVAL"
done
