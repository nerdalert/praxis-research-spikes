# MaaS/Praxis V3 Dataplane Demo

This is a portable, disposable Kind qualification for the basic MaaS V3
datapath. It demonstrates Praxis replacing Envoy as the tenant inference
gateway while MaaS remains the product control plane:

```text
Client
  -> Praxis tenant gateway
     -> Authorino authentication and model authorization
     -> Limitador request quota
     -> Praxis route selection
        -> generated KServe model Service
        -> or direct ExternalModel provider
  <- streamed response
```

The demonstrated inference paths contain no Envoy forwarding hop. Authorino
and Limitador remain authoritative through the POC adapters; those adapters
are explicitly temporary plumbing and are not product integrations.

This directory will contain the reproducible Kind demonstration for replacing
the tenant Envoy inference path with Praxis while retaining MaaS as the product
control plane.

Read the [architecture and research spike](../../research/praxis-maas-v3-data-path-spike.md)
before changing the demo. It defines component ownership, request ordering,
security requirements, supported claims, and outstanding work.

## Intended Demo

```text
Client -> Praxis -> Authorino -> Limitador
       -> KServe Service
       -> EPP-selected KServe endpoint
       -> ExternalModel provider
```

Praxis is the tenant-facing proxy and final-hop client. KServe routing targets
the Service generated for the run-owned model resource. ExternalModel routing
uses the run-owned HTTPS provider fixtures directly. The selected request
paths contain no Envoy forwarding hop and no standalone ExtProc service.

The completed directory should include:

- a cold Kind provisioner with pinned dependencies and bounded readiness;
- declarative manifests and generated overlays;
- a full qualification script and a shorter presentation script;
- deterministic KServe and HTTPS provider fixtures;
- sanitized evidence and expected demo output;
- cleanup that is automatic, scoped, and repeatable; and
- source and image provenance for every run.

The demo must identify the temporary authorization bridge and simulated KServe
backend as research components. Request-count quota must not be presented as
token reservation or settlement.

## Image strategy

The demo deploys only immutable `name@sha256:digest` references. There are no
tag defaults, `latest` fallbacks, or implicit local builds. Every digest is a
required input and is recorded with its source branch and commit before the
run starts. Unchanged infrastructure remains on its pinned upstream release
images and is not republished as a spike image.

| Image | Purpose | Source branch | Digest |
| --- | --- | --- | --- |
| `ghcr.io/nerdalert/praxis` | Praxis plus the AI dataplane build | [`nerdalert/ai@praxis-maas-dp3-poc`](https://github.com/nerdalert/ai/tree/praxis-maas-dp3-poc) | `sha256:ca819d26f16bb04949c773248b34ca3eb56f58c20406bb47f396319f3c6a10df` |
| `ghcr.io/nerdalert/praxis-maas-authz-bridge` | Temporary Authorino/Limitador POC adapter | [research-spikes `main`](https://github.com/nerdalert/praxis-research-spikes/tree/main) | `sha256:ab62af696f9e071f9edfcd1666b7d066ec330d80325d4ed18c89968d93767e0c` |
| `ghcr.io/nerdalert/maas-praxis-v3-provider-fixture` | Deterministic HTTPS Provider A/B fixture | [research-spikes `main`](https://github.com/nerdalert/praxis-research-spikes/tree/main) | required run input: `PROVIDER_FIXTURE_IMAGE` |
| `ghcr.io/nerdalert/maas-praxis-v3-ai-gateway-controller` | V3 ExternalModel/Gateway controller build | [`ai-gateway-controller@main`](https://github.com/nerdalert/ai-gateway-controller/tree/main) | required run input: `AI_GATEWAY_CONTROLLER_IMAGE` |
| `ghcr.io/nerdalert/maas-praxis-v3-runtime-reconciler` | Temporary in-cluster snapshot compiler | [research-spikes `main`](https://github.com/nerdalert/praxis-research-spikes/tree/main) | required run input: `RUNTIME_RECONCILER_IMAGE` |

The two published digests above are the currently qualified images. The other
three image references are intentionally incomplete until their public image
digests are published; a qualification must fail closed if any is absent.
Build and publish those images from the linked source branch, then pass the
resulting digest-pinned references explicitly. The evidence must include the
image reference, source repository, branch, commit, and observed Pod digest.

For contributor validation before those two fixture images are published, use
the explicit source-build switch. This is not the reproducibility default and
does not permit an implicit fallback:

```bash
./scripts/run-demo.sh ... --build-local-fixtures
```

For the currently qualified Praxis image:

```bash
export PRAXIS_AI_IMAGE='ghcr.io/nerdalert/praxis@sha256:ca819d26f16bb04949c773248b34ca3eb56f58c20406bb47f396319f3c6a10df'
```

## Code branches

These are the fork branches that define the changed source surface for the
spike. The remaining Kubernetes, KServe, Gateway API, Authorino, Kuadrant, and
Limitador components are unchanged upstream dependencies.

| Repository branch | Role |
| --- | --- |
| [`nerdalert/praxis@main`](https://github.com/nerdalert/praxis/tree/main) | Praxis core |
| [`nerdalert/ai@praxis-maas-dp3-poc`](https://github.com/nerdalert/ai/tree/praxis-maas-dp3-poc) | Praxis AI dataplane integration |
| [`nerdalert/ai-gateway-controller@main`](https://github.com/nerdalert/ai-gateway-controller/tree/main) | ExternalModel and Gateway reconciliation |
| [`nerdalert/ai-gateway-operator@main`](https://github.com/nerdalert/ai-gateway-operator/tree/main) | Product packaging fork; currently private or not published |
| [`nerdalert/models-as-a-service@main`](https://github.com/nerdalert/models-as-a-service/tree/main) | MaaS control-plane source |
| [`nerdalert/praxis-research-spikes@main`](https://github.com/nerdalert/praxis-research-spikes/tree/main) | This demo and research artifacts |

## Provider and route identity

Provider upstreams are run-owned Services, not abstract names. The demo must
resolve and use the namespace-qualified DNS names:

```text
provider-a-fixture.<run-namespace>.svc.cluster.local
provider-b-fixture.<run-namespace>.svc.cluster.local
```

Do not use nonexistent `provider-a` or `provider-b` names. Provider A and B
must be created before Praxis starts, and their TLS identities, credentials,
and Service endpoints must be ready before the generated configuration is
published.

The KServe route must be compiled from the canonical namespace-prefixed Chat
Completions rule and must target the generated model Service. The compiler
must reject missing or ambiguous canonical matches rather than guessing a
route or falling back to a stale snapshot.

Quota and API-key revocation are separate qualifications. They must use
different run-owned keys so that a quota exhaustion result cannot mask a
revocation result.

## Provisioning and command contract

The portable runner bootstraps the pinned source revisions into a temporary
workspace, then runs the checked-in cold provisioner. No sibling checkout or
developer filesystem path is required. These commands are the reproducibility
contract for the default Service path:

```bash
RUN_ID="maas-v3-$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="$PWD/evidence/$RUN_ID"
export PRAXIS_AI_IMAGE='<required digest-pinned Praxis AI image>'

# Deploy, qualify, write sanitized evidence, and clean up on success/failure.
./scripts/run-demo.sh \
  --run-id "$RUN_ID" \
  --praxis-ai-image "$PRAXIS_AI_IMAGE" \
  --authz-bridge-image 'ghcr.io/nerdalert/praxis-maas-authz-bridge@sha256:ab62af696f9e071f9edfcd1666b7d066ec330d80325d4ed18c89968d93767e0c' \
  --provider-fixture-image 'ghcr.io/nerdalert/maas-praxis-v3-provider-fixture@sha256:<provider-fixture-digest>' \
  --controller-image 'ghcr.io/nerdalert/maas-praxis-v3-ai-gateway-controller@sha256:<controller-digest>' \
  --evidence-dir "$EVIDENCE_DIR"

# For diagnosis only: retain run-owned resources after a failure.
./scripts/run-demo.sh \
  --run-id "$RUN_ID" \
  --praxis-ai-image "$PRAXIS_AI_IMAGE" \
  --authz-bridge-image 'ghcr.io/nerdalert/praxis-maas-authz-bridge@sha256:ab62af696f9e071f9edfcd1666b7d066ec330d80325d4ed18c89968d93767e0c' \
  --provider-fixture-image 'ghcr.io/nerdalert/maas-praxis-v3-provider-fixture@sha256:<provider-fixture-digest>' \
  --controller-image 'ghcr.io/nerdalert/maas-praxis-v3-ai-gateway-controller@sha256:<controller-digest>' \
  --evidence-dir "$EVIDENCE_DIR" \
  --retain-on-failure

# Explicitly remove one retained run after inspection.
./scripts/cleanup.sh --run-id "$RUN_ID"
```

The provisioning order is part of the qualification: infrastructure and
webhooks, immutable images, provider Services/TLS/credentials, ExternalProvider
and ExternalModel resources, MaaS model and policy resources, one coherent
Praxis configuration revision, and finally Praxis readiness. Requests must not
start before the final readiness gate.

Names, namespaces, certificates, credentials, temporary files, and evidence
must be run-owned. Cleanup is automatic by default, scoped to the run ID, and
must preserve unrelated Kind clusters, namespaces, networks, files, and
credentials. Retention is an explicit failure-diagnosis option, not the normal
qualification mode.

## Qualification gates

The full run must record distinct PASS/FAIL gates for:

- anonymous and invalid-key denial;
- authorized KServe Service success;
- authorized ExternalModel success with provider attribution;
- quota denial before backend contact;
- independent revoked-key denial;
- caller credential stripping and provider-credential injection;
- unknown-model fail-closed behavior;
- early streaming chunk before completion;
- KServe and ExternalModel coexistence on one Praxis listener;
- absence of an Envoy forwarding hop; and
- cleanup of every run-owned resource and credential.

Evidence must include the image/source provenance, route and Service identity,
backend-contact counters, response status, provider attribution, streaming
timestamps, and cleanup verification. It must contain no credential values,
tokens, private keys, kubeconfigs, or unsanitized local paths.

## Explicitly excluded from this demo

This qualification does not demonstrate InferencePool, EPP scheduling,
llm-d scheduling, or full-duplex llm-d ExtProc behavior. It does not add an
Envoy hop to either inference path. It also does not claim production parity
for the temporary authorization bridge, request-count quota versus token
reservation/settlement, real vLLM serving, OpenShift, or RHOAI. Those require
separate qualification and product work.
