#!/usr/bin/env bash
set -euo pipefail

# POC control-plane writer: derive the serving candidates from the live
# ExternalModel provider refs. Provider endpoint/TLS/credential contracts are
# explicit fixture inputs; Praxis only receives the resulting revision.
namespace=${1:?namespace}
model=${2-}
output=${3:?output}

if [[ -z "$model" ]]; then
  external='{"metadata":{"generation":0,"uid":"no-external-model"},"spec":{"externalProviderRefs":[]}}'
else
  external=$(kubectl -n "$namespace" get externalmodel "$model" -o json)
fi

# Provider identity and eligibility come from the current ExternalModel and
# ExternalProvider objects.  The generated Praxis cluster/credential names are
# the controller's stable POC naming contract, not a provider allow-list.
jq -n --argjson external "$external" --arg namespace "$namespace" '
  def provider_id($ref): ($ref.ref.name | sub("^provider-";""));
  def candidate($ref;$group): {
    cluster:("provider-provider-" + provider_id($ref)), kind:"inference_model",
    name:$external.metadata.name, site:"local", fresh:true,
    selection_group:$group, stable_id:("provider-provider-" + provider_id($ref)),
    credential:{strategy:"bearer_token",secretRef:{name:("provider-" + provider_id($ref) + "-credentials"),namespace:$namespace,key:"api-key"}}
  };
  {network:"external-model",local_site:"local",
   candidates:([$external.spec.externalProviderRefs[]
     | select((.weight // 0) > 0)
     | . as $ref
     | candidate($ref; ([$external.spec.externalProviderRefs[] | select((.weight // 0) > 0)] | index($ref))) ]),
   selection_policy:{mode:"deterministic"}}' > "$output.content"

content_digest=$(jq -S -c '{candidates,local_site,network,selection_policy}' "$output.content" | tr -d '\n' | sha256sum | awk '{print $1}')
generation=$(jq -r '.metadata.generation // 1' <<<"$external")
uid=$(jq -r '.metadata.uid // "run-owned-externalmodel"' <<<"$external")
jq -n --arg digest "$content_digest" --argjson generation "$generation" --arg uid "$uid" --arg namespace "$namespace" --arg gateway "${PRAXIS_GATEWAY:-maas-default-gateway}" --argjson overlay "$(cat "$output.content")" '
  {schema_version:"1.0.0",
   revision:{kind:"content_addressed",algorithm:"sha256",value:$digest},
   content_digest:{algorithm:"sha256",value:$digest},
   scope:{network:$overlay.network,gateway:$gateway,namespace:$namespace,local_site:$overlay.local_site},
   provenance:{producer:"poc-runtime-reconciler",producer_version:"1",source_name:$overlay.network,source_uid:$uid,source_generation:$generation,rendered_at:"2026-09-22T00:00:00Z"},
   overlay:$overlay}' > "$output"
rm -f "$output.content"

jq -e '.overlay.candidates | type == "array"' "$output" >/dev/null
