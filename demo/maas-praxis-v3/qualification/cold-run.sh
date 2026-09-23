#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RUN_ID=${RUN_ID:-poc-e2e-cold-20260922-$(date -u +%H%M%S)}
CLUSTER=${CLUSTER:-maas-praxis-cold-20260922-$(date -u +%H%M%S)}
KEEP_CLUSTER=${KEEP_CLUSTER:-false}
PRAXIS_AI_IMAGE=${PRAXIS_AI_IMAGE:-}
REQUIRE_PRAXIS_AI_IMAGE=${REQUIRE_PRAXIS_AI_IMAGE:-false}
AUTHZ_BRIDGE_IMAGE=${AUTHZ_BRIDGE_IMAGE:-}
PROVIDER_FIXTURE_IMAGE=${PROVIDER_FIXTURE_IMAGE:-}
AI_GATEWAY_CONTROLLER_IMAGE=${AI_GATEWAY_CONTROLLER_IMAGE:-}
EVIDENCE="${EVIDENCE_ROOT:-$ROOT/evidence/$RUN_ID}"
mkdir -p "$EVIDENCE"
exec > >(tee "$EVIDENCE/00-cold-run.log") 2>&1
RECONCILER_PID=""
EXIT_STATUS=0
CLUSTER_CREATED=false
cleanup() {
  if [[ -n "$RECONCILER_PID" ]]; then kill "$RECONCILER_PID" 2>/dev/null || true; fi
  if [[ "$EXIT_STATUS" != "0" && "$CLUSTER_CREATED" == "true" ]]; then
    {
      echo "failure_diagnostics cluster=$CLUSTER stage=${STAGE:-unknown} status=$EXIT_STATUS"
      kubectl get maasmodelref,maasauthpolicy,maassubscription,externalmodel,externalprovider -A -o yaml 2>&1 || true
      kubectl -n kuadrant-system get authconfig,limitador -o yaml 2>&1 || true
      kubectl -n maas-praxis-system get events --sort-by=.lastTimestamp 2>&1 || true
      kubectl -n maas-praxis-system logs deployment/maas-controller --all-containers --tail=300 2>&1 || true
      kubectl -n models-as-a-service logs deployment/praxis-maas-authz --all-containers --tail=300 2>&1 || true
      kubectl -n models-as-a-service logs deployment/praxis-service-poc --all-containers --tail=300 2>&1 || true
      kubectl -n maas-praxis-system logs deployment/provider-a-fixture --all-containers --tail=300 2>&1 || true
      kubectl -n maas-praxis-system logs deployment/provider-b-fixture --all-containers --tail=300 2>&1 || true
      kubectl -n llm-internal logs deployment/praxis-sim-kserve --all-containers --tail=300 2>&1 || true
    } > "$EVIDENCE/failure-diagnostics.txt"
  fi
  if [[ "$KEEP_CLUSTER" != "true" ]] && kind get clusters 2>/dev/null | grep -Fxq "$CLUSTER"; then
    kind delete cluster --name "$CLUSTER" || true
  fi
}
on_exit() { EXIT_STATUS=$?; cleanup; exit "$EXIT_STATUS"; }
trap on_exit EXIT
trap 'rc=$?; echo "FIRST_FAILURE stage=${STAGE:-unknown} rc=$rc"; kubectl get pods -A -o wide || true; exit $rc' ERR

export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
KIND_NODE=${KIND_NODE:-kindest/node:v1.35.0}
STAGE=prerequisites
command -v kind kubectl kustomize helm jq openssl docker >/dev/null
ISTIOCTL="$ROOT/istio-1.29.2/bin/istioctl"
[[ -x "$ISTIOCTL" ]] || { echo "missing $ISTIOCTL"; exit 2; }

STAGE=source-audit
for repo in ai ai-gateway-controller ai-gateway-operator authorino gateway-api-inference-extension kserve kuadrant-operator limitador models-as-a-service praxis praxis-extproc; do
  git -C "$ROOT/$repo" rev-parse HEAD | sed "s#^#$repo #" | tee -a "$EVIDENCE/01-source-shas.txt"
  git -C "$ROOT/$repo" status --short | tee -a "$EVIDENCE/02-source-dirty.txt"
done

STAGE=build-images
TAG="$RUN_ID"
if [[ -n "$AUTHZ_BRIDGE_IMAGE" ]]; then
  AUTHZ_IMAGE="$AUTHZ_BRIDGE_IMAGE"
else
  docker build -t "praxis-maas-authz-bridge:$TAG" "$ROOT/authz-bridge"
  AUTHZ_IMAGE="praxis-maas-authz-bridge:$TAG"
fi
if [[ "$REQUIRE_PRAXIS_AI_IMAGE" == "true" && -z "$PRAXIS_AI_IMAGE" ]]; then
  echo "PRAXIS_AI_IMAGE is required for this qualification" >&2
  exit 2
fi
if [[ -n "$PRAXIS_AI_IMAGE" ]]; then
  [[ "$PRAXIS_AI_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]] || {
    echo "PRAXIS_AI_IMAGE must be digest-pinned (name@sha256:...)" >&2
    exit 2
  }
  PRAXIS_IMAGE="$PRAXIS_AI_IMAGE"
else
  docker build -t "praxis-ai-service-poc:$TAG" -f "$ROOT/ai/Containerfile" "$ROOT/ai"
  PRAXIS_IMAGE="praxis-ai-service-poc:$TAG"
fi
if [[ -n "$AUTHZ_BRIDGE_IMAGE" ]]; then
  [[ "$AUTHZ_BRIDGE_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]] || {
    echo "AUTHZ_BRIDGE_IMAGE must be digest-pinned (name@sha256:...)" >&2
    exit 2
  }
  AUTHZ_IMAGE="$AUTHZ_BRIDGE_IMAGE"
fi
if [[ -n "$PROVIDER_FIXTURE_IMAGE" ]]; then
  [[ "$PROVIDER_FIXTURE_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]] || { echo "PROVIDER_FIXTURE_IMAGE must be digest-pinned" >&2; exit 2; }
  PROVIDER_IMAGE="$PROVIDER_FIXTURE_IMAGE"
else
  docker build -t "provider-fixture:$TAG" "$ROOT/fixtures/provider-fixture"
  PROVIDER_IMAGE="provider-fixture:$TAG"
fi
if [[ -n "$AI_GATEWAY_CONTROLLER_IMAGE" ]]; then
  [[ "$AI_GATEWAY_CONTROLLER_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]] || { echo "AI_GATEWAY_CONTROLLER_IMAGE must be digest-pinned" >&2; exit 2; }
  CONTROLLER_IMAGE="$AI_GATEWAY_CONTROLLER_IMAGE"
else
  docker build -t "ai-gateway-controller:$TAG" "$ROOT/ai-gateway-controller"
  CONTROLLER_IMAGE="ai-gateway-controller:$TAG"
fi
{
  if [[ -n "$AUTHZ_BRIDGE_IMAGE" ]]; then echo "authz-bridge $AUTHZ_IMAGE source=ghcr-explicit-input"; else docker image inspect "praxis-maas-authz-bridge:$TAG" --format '{{index .RepoTags 0}} {{.Id}}'; fi
  if [[ -n "$PROVIDER_FIXTURE_IMAGE" ]]; then echo "provider-fixture $PROVIDER_IMAGE source=ghcr-explicit-input"; else docker image inspect "$PROVIDER_IMAGE" --format '{{index .RepoTags 0}} {{.Id}}'; fi
  if [[ -n "$AI_GATEWAY_CONTROLLER_IMAGE" ]]; then echo "ai-gateway-controller $CONTROLLER_IMAGE source=ghcr-explicit-input"; else docker image inspect "$CONTROLLER_IMAGE" --format '{{index .RepoTags 0}} {{.Id}}'; fi
  if [[ -n "$PRAXIS_AI_IMAGE" ]]; then
    echo "praxis-ai $PRAXIS_IMAGE source=ghcr-explicit-input"
  else
    docker image inspect "$PRAXIS_IMAGE" --format '{{index .RepoTags 0}} {{.Id}}'
  fi
} | tee "$EVIDENCE/03-image-provenance.txt"
printf 'scheduler=none\nroute=KServe-generated Service\n' | tee "$EVIDENCE/04-service-route-provenance.txt"

STAGE=cluster
if kind get clusters | grep -Fxq "$CLUSTER"; then
  echo "reusing run-owned cold cluster $CLUSTER after a provisioner failure"
else
  kind create cluster --name "$CLUSTER" --image "$KIND_NODE" --wait 120s
fi
kubectl config use-context "kind-$CLUSTER"
CLUSTER_CREATED=true
local_images=()
[[ -z "$PROVIDER_FIXTURE_IMAGE" ]] && local_images+=("provider-fixture:$TAG")
[[ -z "$AI_GATEWAY_CONTROLLER_IMAGE" ]] && local_images+=("ai-gateway-controller:$TAG")
[[ -z "$AUTHZ_BRIDGE_IMAGE" ]] && local_images+=("praxis-maas-authz-bridge:$TAG")
[[ -z "$PRAXIS_AI_IMAGE" ]] && local_images+=("$PRAXIS_IMAGE")
(( ${#local_images[@]} == 0 )) || kind load docker-image "${local_images[@]}" --name "$CLUSTER"

STAGE=gateway-api
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml

STAGE=istio
"$ISTIOCTL" install --set profile=minimal -y
kubectl wait --for=condition=available deployment/istiod -n istio-system --timeout=180s
kubectl set env deployment/istiod -n istio-system ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true PILOT_ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true
kubectl rollout status deployment/istiod -n istio-system --timeout=180s

STAGE=metallb
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
kubectl wait --for=condition=available deployment/controller -n metallb-system --timeout=180s
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: {name: kind-pool, namespace: metallb-system}
spec: {addresses: [172.20.0.200-172.20.0.250]}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: {name: kind-l2, namespace: metallb-system}
EOF

STAGE=cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.yaml
kubectl wait --for=condition=available deployment/cert-manager -n cert-manager --timeout=180s
kubectl wait --for=condition=available deployment/cert-manager-webhook -n cert-manager --timeout=180s

STAGE=namespaces-and-tls
kubectl create namespace maas-praxis-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace maas-praxis-gateway --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace models-as-a-service --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace llm-internal --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f <(cat <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: maas-selfsigned-issuer}
spec: {selfSigned: {}}
EOF
)
kubectl apply -f "$ROOT/qualification/maas-ca.yaml"
kubectl wait --for=condition=Ready certificate/maas-root-ca -n maas-praxis-system --timeout=180s
kubectl get secret maas-root-ca -n maas-praxis-system -o json | jq 'del(.metadata.namespace,.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.managedFields,.metadata.ownerReferences)' | jq '.metadata.namespace="cert-manager"' | kubectl apply -f -
kubectl wait --for=condition=Ready clusterissuer/rhai-ca-issuer --timeout=180s
kubectl apply -f "$ROOT/controller-certs.yaml"
kubectl apply -f "$ROOT/gateway-certificate.yaml"

STAGE=kuadrant
helm repo add kuadrant https://kuadrant.io/helm-charts >/dev/null 2>&1 || true
helm repo update
helm upgrade --install kuadrant-operator kuadrant/kuadrant-operator --version 1.3.1 -n kuadrant-system --create-namespace --wait --timeout 5m
kubectl apply -f <(cat <<'EOF'
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata: {name: kuadrant, namespace: kuadrant-system}
EOF
)
for _ in $(seq 1 60); do
  if kubectl get deployment/authorino -n kuadrant-system >/dev/null 2>&1; then break; fi
  sleep 5
done
kubectl wait --for=condition=available deployment/authorino -n kuadrant-system --timeout=300s
# Authorino must validate MaaS's internal HTTPS certificate. Project the
# run-generated root CA through the supported Authorino volume contract; no
# insecure TLS bypass is used.
kubectl get secret maas-root-ca -n maas-praxis-system -o json | jq 'del(.metadata.namespace,.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.managedFields,.metadata.ownerReferences) | .metadata.name="authorino-maas-ca" | .metadata.namespace="kuadrant-system"' | kubectl apply -f -
kubectl -n kuadrant-system patch authorino authorino --type=merge -p '{"spec":{"volumes":{"defaultMode":420,"items":[{"name":"maas-ca","mountPath":"/etc/maas-ca","secrets":["authorino-maas-ca"],"items":[{"key":"tls.crt","path":"tls.crt"}]}]}}}'
# Authorino's CRD exposes the volume but not process environment.  The
# run-owned custom MaaS API CA therefore needs this explicit generated-workload
# trust projection; without it Authorino fails closed on the real HTTPS
# metadata call.  This is qualification plumbing, not a product-side policy
# bypass.
kubectl -n kuadrant-system set env deployment/authorino SSL_CERT_FILE=/etc/maas-ca/tls.crt
kubectl -n kuadrant-system rollout status deployment/authorino --timeout=120s

STAGE=postgres
kubectl apply -f "$ROOT/qualification/postgres.yaml"
kubectl rollout status deployment/postgres -n maas-praxis-system --timeout=180s

STAGE=kserve
kubectl create namespace kserve --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$ROOT/kserve/config/certmanager/issuer.yaml"
kubectl apply --server-side -k "$ROOT/kserve/config/default"
kubectl apply --server-side -f "$ROOT/kserve/config/configmap/inferenceservice.yaml"
kubectl scale deployment/kserve-controller-manager -n kserve --replicas=0
kubectl apply --server-side -k "$ROOT/kserve/config/crd/full/llmisvc"
for llm_crd in llminferenceservices.serving.kserve.io llminferenceserviceconfigs.serving.kserve.io; do
  kubectl wait --for=create "crd/$llm_crd" --timeout=30s
  established=0
  until kubectl get crd "$llm_crd" -o json | jq -e '.status.conditions[]? | select(.type == "Established" and .status == "True")' >/dev/null; do
    established=$((established + 1))
    (( established < 120 )) || { echo "CRD_NOT_ESTABLISHED crd=$llm_crd" >&2; exit 1; }
    sleep 1
  done
done
kubectl apply --server-side -k "$ROOT/kserve/config/llmisvc"
kubectl rollout status deployment/llmisvc-controller-manager -n kserve --timeout=300s
webhook_attempt=0
until [[ "$(kubectl -n kserve get endpoints llmisvc-webhook-server-service -o json 2>/dev/null | jq '[.subsets[]?.addresses[]?] | length')" -gt 0 ]]; do
  webhook_attempt=$((webhook_attempt + 1))
  (( webhook_attempt < 120 )) || { echo "LLMISVC_WEBHOOK_ENDPOINT_NOT_READY attempts=$webhook_attempt" >&2; kubectl -n kserve get pods,svc,endpoints llmisvc-webhook-server-service -o wide >&2 || true; exit 1; }
  sleep 1
done
llmisvcconfig_attempt=0
until kubectl apply --server-side -k "$ROOT/kserve/config/llmisvcconfig"; do
  llmisvcconfig_attempt=$((llmisvcconfig_attempt + 1))
  (( llmisvcconfig_attempt < 30 )) || { echo "LLMISVC_CONFIG_ADMISSION_FAILED attempts=$llmisvcconfig_attempt" >&2; exit 1; }
  sleep 2
done

STAGE=gateway
kubectl apply -f <(cat <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: maas-default-gateway, namespace: maas-praxis-gateway}
spec:
  gatewayClassName: istio
  listeners:
  - {name: http, port: 80, protocol: HTTP, allowedRoutes: {namespaces: {from: All}}}
  - name: https
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - kind: Secret
        name: maas-gateway-tls
    allowedRoutes: {namespaces: {from: All}}
EOF
)
kubectl wait --for=condition=programmed gateway/maas-default-gateway -n maas-praxis-gateway --timeout=180s

STAGE=maas
kubectl apply -k "$ROOT/qualification/maas-cold-overlay"
kubectl apply -f "$ROOT/maas-config.yaml"
kubectl rollout status deployment/maas-controller -n maas-praxis-system --timeout=300s

STAGE=fixtures
kubectl apply -f "$ROOT/qualification/tenant-config.yaml"
ai_gateway_overlay_tmp=$(mktemp -d "$ROOT/qualification/.ai-gateway-overlay.XXXXXX")
cp "$ROOT/qualification/ai-gateway-controller-cold-overlay/kustomization.yaml" "$ai_gateway_overlay_tmp/kustomization.yaml"
sed -i "s#__RUN_TAG__#$TAG#g" "$ai_gateway_overlay_tmp/kustomization.yaml"
kustomize build "$ai_gateway_overlay_tmp" | kubectl apply -f -
rm -rf "$ai_gateway_overlay_tmp"
kubectl rollout status deployment/ai-gateway-controller -n maas-praxis-system --timeout=180s

# MaaS and the Praxis controller coordinate the legacy-IPP handoff through
# the durable payload-processing-status marker. Do not create model objects
# while that handshake is still in flight: otherwise ExternalModel can see a
# generated HTTPRoute that is still being removed. This also proves that the
# controller is consuming AITenant.status.gatewayRef rather than a harness
# parent-reference patch.
tenant_attempt=0
until kubectl -n models-as-a-service get maastenantconfig default-tenant -o json 2>/dev/null |
  jq -e '.metadata.annotations["maas.opendatahub.io/payload-processing-status"] == "steady"' >/dev/null &&
  kubectl get aitenant -A -o json 2>/dev/null |
  jq -e '[.items[] | select(.status.phase == "Active" and (.status.gatewayRef.name // "") != "" and (.status.gatewayRef.namespace // "") != "")] | length == 1' >/dev/null; do
  tenant_attempt=$((tenant_attempt + 1))
  if (( tenant_attempt >= 90 )); then
    echo "TENANT_HANDOFF_NOT_READY attempts=$tenant_attempt" >&2
    kubectl -n models-as-a-service get maastenantconfig default-tenant -o yaml >&2 || true
    kubectl get aitenant -A -o yaml >&2 || true
    exit 1
  fi
  sleep 2
done
kubectl -n models-as-a-service get maastenantconfig default-tenant -o yaml > "$EVIDENCE/tenant-config-ready.yaml"
kubectl get aitenant -A -o yaml > "$EVIDENCE/aitenant-ready.yaml"
apply_maas_fixture() {
  local fixture=$1 attempt=0
  until kubectl apply -f "$ROOT/$fixture"; do
    attempt=$((attempt + 1))
    (( attempt < 30 )) || { echo "MAAS_FIXTURE_ADMISSION_FAILED fixture=$fixture attempts=$attempt" >&2; exit 1; }
    sleep 2
  done
}
apply_maas_fixture internal-fixture.yaml
kubectl wait --for=condition=Ready llminferenceservice/praxis-sim -n llm-internal --timeout=300s

STAGE=provider-secrets
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; cleanup' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/ca.key" -out "$tmp/ca.crt" -subj /CN=poc-ca -days 2 >/dev/null 2>&1
for p in a b; do openssl req -newkey rsa:2048 -nodes -keyout "$tmp/$p.key" -out "$tmp/$p.csr" -subj "/CN=provider-$p.maas-praxis-system.svc.cluster.local" >/dev/null 2>&1; printf 'subjectAltName=DNS:provider-%s.maas-praxis-system.svc.cluster.local\n' "$p" > "$tmp/$p.ext"; openssl x509 -req -in "$tmp/$p.csr" -CA "$tmp/ca.crt" -CAkey "$tmp/ca.key" -CAcreateserial -out "$tmp/$p.crt" -days 2 -sha256 -extfile "$tmp/$p.ext" >/dev/null 2>&1; done
kubectl -n maas-praxis-system create secret tls provider-a-tls --cert="$tmp/a.crt" --key="$tmp/a.key" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n maas-praxis-system create secret tls provider-b-tls --cert="$tmp/b.crt" --key="$tmp/b.key" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n models-as-a-service create secret generic provider-ca --from-file=ca.crt="$tmp/ca.crt" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n models-as-a-service create secret generic provider-a-credentials --from-literal=api-key=provider-a-strict-key --dry-run=client -o yaml | kubectl apply -f -
kubectl -n models-as-a-service create secret generic provider-b-credentials --from-literal=api-key=provider-b-strict-key --dry-run=client -o yaml | kubectl apply -f -
# The immutable provider image is already loaded before this stage. Apply the
# run-owned fixture before MaaS model references so the controller never sees
# an ExternalModel reference whose object is absent.
sed -e "s#provider-fixture:poc-e2e-20260922#$PROVIDER_IMAGE#g" "$ROOT/external-provider-fixture.yaml" | kubectl apply -f -
governance_attempt=0
until kubectl apply -f "$ROOT/external-maas-governance.yaml"; do
  governance_attempt=$((governance_attempt + 1))
  (( governance_attempt < 30 )) || { echo "MAAS_GOVERNANCE_ADMISSION_FAILED attempts=$governance_attempt" >&2; exit 1; }
  sleep 2
done

# ExternalModel routing is owned by the AI Gateway controller.  Its runtime
# resolver only accepts provider references whose persisted status is Ready;
# do not wait for the later ExternalModel condition and hide a provider-schema,
# namespace, Secret, or controller-image mismatch behind a generic timeout.
capture_external_provider_diagnostics() {
  local out="$EVIDENCE/external-provider-diagnostics"
  mkdir -p "$out"
  kubectl -n models-as-a-service get externalmodel praxis-external -o yaml > "$out/externalmodel.yaml" 2>&1 || true
  kubectl -n models-as-a-service get externalprovider -o yaml > "$out/externalproviders.yaml" 2>&1 || true
  kubectl -n models-as-a-service get secret provider-a-credentials provider-b-credentials provider-ca \
    -o json 2>"$out/provider-secrets.err" |
    jq 'del(.items[]?.data, .items[]?.stringData, .items[]?.metadata.managedFields, .items[]?.metadata.resourceVersion, .items[]?.metadata.uid, .items[]?.metadata.creationTimestamp)' \
    > "$out/provider-secrets-sanitized.json" || true
  kubectl -n models-as-a-service get events --sort-by=.lastTimestamp > "$out/events.txt" 2>&1 || true
  kubectl -n maas-praxis-system get deployment ai-gateway-controller -o yaml > "$out/controller-deployment.yaml" 2>&1 || true
  kubectl -n maas-praxis-system logs deployment/ai-gateway-controller --all-containers --tail=500 > "$out/controller.log" 2>&1 || true
  kubectl -n models-as-a-service get maasmodelref praxis-external -o yaml > "$out/maasmodelref.yaml" 2>&1 || true
  {
    echo "ExternalModel provider references and persisted readiness:"
    kubectl -n models-as-a-service get externalmodel praxis-external \
      -o json | jq -r '.spec.externalProviderRefs[]? | [.ref.name, (.weight // 1)] | @tsv' || true
    kubectl -n models-as-a-service get externalprovider \
      -o json | jq -r '.items[] | [.metadata.namespace, .metadata.name, (.status.phase // "<missing>"), (.status.observedGeneration // 0), (.spec.endpoint // "<missing>"), (.spec.provider // "<missing>"), (.spec.auth.type // "<missing>"), (.spec.auth.secretRef.name // "<missing>")] | @tsv' || true
  } > "$out/provider-resolution-summary.tsv"
}

# Start the snapshot compiler before waiting for ExternalModel readiness. The
# controller needs the generated overlay to publish the ExternalModel route,
# so waiting first creates a readiness deadlock.
STAGE=runtime-reconciler
NAMESPACE=models-as-a-service INTERVAL=2 OUT_DIR="$EVIDENCE/runtime-reconciler" \
  "$ROOT/qualification/reconcile-runtime.sh" > "$EVIDENCE/runtime-reconciler.log" 2>&1 &
RECONCILER_PID=$!

provider_ready_deadline=$((SECONDS + 60))
provider_ready=false
while (( SECONDS < provider_ready_deadline )); do
  provider_ready=$(kubectl -n models-as-a-service get externalprovider provider-a provider-b -o json 2>/dev/null |
    jq -e '(.items | length == 2) and all(.items[]; .status.phase == "Ready" and (.status.observedGeneration // 0) >= (.metadata.generation // 0))' >/dev/null && echo true || echo false)
  [[ "$provider_ready" == true ]] && break
  sleep 2
done
if [[ "$provider_ready" != true ]]; then
  capture_external_provider_diagnostics
  echo "EXTERNAL_PROVIDER_NOT_READY: provider refs must resolve to Ready providers before ExternalModel routing" >&2
  cat "$EVIDENCE/external-provider-diagnostics/provider-resolution-summary.tsv" >&2 || true
  exit 1
fi

STAGE=generated-policy
kubectl wait --for=condition=Ready llminferenceservice/praxis-sim -n llm-internal --timeout=300s || true
kubectl wait --for=condition=Ready externalmodel/praxis-external -n models-as-a-service --timeout=300s || true

expected_models=$(kubectl get maasmodelref -A -o json | jq '.items | length')
external_limit_attempt=0
until [[ "$(kubectl -n kuadrant-system get limitador limitador -o json | jq '[.spec.limits[]?] | length')" -ge "$expected_models" ]]; do
  external_limit_attempt=$((external_limit_attempt + 1))
  (( external_limit_attempt < 60 )) || { echo "LIMIT_POLICY_NOT_GENERATED expected=$expected_models attempts=$external_limit_attempt" >&2; exit 1; }
  sleep 2
done

# The snapshot compiler derives every route, Authorino scope, Limitador
# descriptor, backend kind, and provider overlay from current cluster state.
# No route/rule/domain/hash is copied from a retained run.
kubectl -n kuadrant-system get authconfig -o json > "$EVIDENCE/generated-authconfigs.json"
kubectl -n kuadrant-system get limitador limitador -o json > "$EVIDENCE/generated-limitador.json"

# KServe's no-scheduler route is a real URL contract: the client-facing
# prefix is generated from the LLMInferenceService name/namespace and the
# HTTPRoute rewrites it to the serving API path.  Praxis is the final hop in
# this mode, so compile that prefix from the live generated route rather than
# duplicating a fixture name in the Praxis config.
STAGE=route-compilation
kubectl -n llm-internal get httproute praxis-sim-kserve-route -o json > "$EVIDENCE/kserve-service-httproute.json"
kserve_route_compiled=$("$ROOT/qualification/compile-kserve-service-route.sh" \
  "$EVIDENCE/kserve-service-httproute.json" praxis-sim-kserve-workload-svc 8000 llm-internal)
kserve_path_prefix=$(jq -r '.clientPrefix' <<<"$kserve_route_compiled")
kserve_backend_path=$(jq -r '.backendRewrite' <<<"$kserve_route_compiled")
[[ "$kserve_path_prefix" =~ ^/[A-Za-z0-9._/-]+$ ]] || {
  echo "KSERVE_ROUTE_PREFIX_INVALID value=$kserve_path_prefix" >&2
  exit 1
}
[[ "$kserve_backend_path" =~ ^/[A-Za-z0-9._/-]+$ ]] || {
  echo "KSERVE_BACKEND_REWRITE_INVALID value=$kserve_backend_path" >&2
  exit 1
}
{
  echo "source=llm-internal/praxis-sim-kserve-route"
  echo "backend_service=llm-internal/praxis-sim-kserve-workload-svc:8000"
  echo "client_prefix=$kserve_path_prefix"
  echo "backend_rewrite=$kserve_backend_path"
  echo "compiler=qualification/compile-kserve-service-route.sh"
} | tee "$EVIDENCE/05-kserve-route-rewrite.txt"

STAGE=service-diagnostic
EVIDENCE="$EVIDENCE" \
  SERVICE_HOST=praxis-sim-kserve-workload-svc.llm-internal.svc.cluster.local \
  SERVICE_PORT=8000 \
  DIRECT_PATH="$kserve_backend_path" \
  EXTERNAL_PATH="${kserve_path_prefix}/v1/chat/completions" \
  bash "$ROOT/qualification/kserve-service-diagnostic.sh"

reconcile_attempt=0
until kubectl -n models-as-a-service get configmap praxis-runtime-snapshot -o json 2>/dev/null | \
  jq -e --argjson expected "$expected_models" '.data["policy.json"] | fromjson | (.routes | length == $expected)' >/dev/null; do
  reconcile_attempt=$((reconcile_attempt + 1))
  (( reconcile_attempt < 60 )) || { echo "RUNTIME_SNAPSHOT_NOT_READY expected=$expected_models attempts=$reconcile_attempt" >&2; exit 1; }
  sleep 2
done
kubectl -n models-as-a-service get configmap praxis-runtime-snapshot -o json > "$EVIDENCE/runtime-snapshot.json"
jq -r '.data["policy.json"]' "$EVIDENCE/runtime-snapshot.json" | tee "$EVIDENCE/generated-policy.json" | jq .
jq -r '.data["routing-overlay.json"]' "$EVIDENCE/runtime-snapshot.json" > "$EVIDENCE/generated-external-routing-overlay.json"

STAGE=provider-and-praxis
sed "s#praxis-maas-authz-bridge:poc-e2e-20260922#$AUTHZ_IMAGE#g" "$ROOT/authz-bridge.yaml" | kubectl apply -f -
sed -e "s#praxis-ai-service-poc:poc-e2e#$PRAXIS_IMAGE#g" \
  -e "s#__KSERVE_SERVICE_PATH_PREFIX__#$kserve_path_prefix#g" \
  -e "s#__KSERVE_BACKEND_PATH__#$kserve_backend_path#g" \
  "$ROOT/praxis-service-poc-deployment.yaml" | kubectl apply -f -
kubectl rollout status deployment/praxis-maas-authz -n models-as-a-service --timeout=180s
kubectl rollout status deployment/praxis-service-poc -n models-as-a-service --timeout=180s

STAGE=qualification
sim_key_response=$(kubectl exec -n maas-praxis-system deployment/maas-api -- curl -sk \
  https://localhost:8443/v1/api-keys \
  -H 'X-MaaS-Username: qualification-sim' \
  -H 'X-MaaS-Group: ["system:authenticated"]' \
  -H 'Content-Type: application/json' \
  -d '{"name":"qualification-sim","subscription":"praxis-subscription"}')
ext_key_response=$(kubectl exec -n maas-praxis-system deployment/maas-api -- curl -sk \
  https://localhost:8443/v1/api-keys \
  -H 'X-MaaS-Username: qualification-external' \
  -H 'X-MaaS-Group: ["system:authenticated"]' \
  -H 'Content-Type: application/json' \
  -d '{"name":"qualification-external","subscription":"praxis-external-subscription"}')
quota_key_response=$(kubectl exec -n maas-praxis-system deployment/maas-api -- curl -sk \
  https://localhost:8443/v1/api-keys \
  -H 'X-MaaS-Username: qualification-quota' \
  -H 'X-MaaS-Group: ["system:authenticated"]' \
  -H 'Content-Type: application/json' \
  -d '{"name":"qualification-quota","subscription":"praxis-subscription"}')
SIM_KEY=$(jq -r '.key // empty' <<<"$sim_key_response")
SIM_KEY_ID=$(jq -r '.id // empty' <<<"$sim_key_response")
EXT_KEY=$(jq -r '.key // empty' <<<"$ext_key_response")
EXT_KEY_ID=$(jq -r '.id // empty' <<<"$ext_key_response")
QUOTA_KEY=$(jq -r '.key // empty' <<<"$quota_key_response")
QUOTA_KEY_ID=$(jq -r '.id // empty' <<<"$quota_key_response")
[[ -n "$SIM_KEY" && -n "$SIM_KEY_ID" && -n "$EXT_KEY" && -n "$EXT_KEY_ID" && -n "$QUOTA_KEY" && -n "$QUOTA_KEY_ID" ]] || {
  echo "QUALIFICATION_API_KEY_CREATION_FAILED" >&2
  exit 1
}
EVIDENCE="$EVIDENCE" SIM_KEY="$SIM_KEY" SIM_KEY_ID="$SIM_KEY_ID" EXT_KEY="$EXT_KEY" EXT_KEY_ID="$EXT_KEY_ID" QUOTA_KEY="$QUOTA_KEY" QUOTA_KEY_ID="$QUOTA_KEY_ID" \
  CLUSTER="$CLUSTER" bash "$ROOT/qualification/service-suite.sh"

kubectl get llminferenceservice,httproute,externalmodel -A -o yaml > "$EVIDENCE/10-generated-state.yaml"
kubectl get pods -A -o wide > "$EVIDENCE/11-pods.txt"
kubectl get deployment -A -o json | jq -r '.items[] | [.metadata.namespace,.metadata.name,.spec.replicas,((.spec.template.spec.containers // [])|map(.image)|join(","))] | @tsv' > "$EVIDENCE/12-images.txt"
echo "COLD_PROVISIONING_COMPLETE cluster=$CLUSTER run=$RUN_ID evidence=$EVIDENCE"
