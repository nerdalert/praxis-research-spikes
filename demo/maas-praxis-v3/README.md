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

## Image Strategy

Use immutable, multi-architecture GHCR images for spike-owned code. This keeps
the demo reproducible and avoids lengthy local Rust and Go builds. Preserve an
explicit source-build mode for contributors and CI validation.

The provisioner must require an explicit digest-pinned reference for every
spike-owned image. It must reject an unset reference, a tag-only reference, or
`latest`; it must not silently build a local replacement. The image reference,
resolved digest, source repository, source branch, and source commit must be
written to sanitized evidence before qualification begins.

The Praxis AI image prepared for this branch is:

```text
repository: https://github.com/nerdalert/ai
branch:     praxis-maas-dp3-poc
commit:     ab6847b3a0ca2e15ac34b80ff858705853e5d012
image:      ghcr.io/nerdalert/praxis@sha256:ca819d26f16bb04949c773248b34ca3eb56f58c20406bb47f396319f3c6a10df
```

Use it explicitly for a qualification run, for example:

```bash
export PRAXIS_AI_IMAGE='ghcr.io/nerdalert/praxis@sha256:ca819d26f16bb04949c773248b34ca3eb56f58c20406bb47f396319f3c6a10df'
```

The value above is an example of an explicit run input, not a hidden default.
The qualification must continue to require `PRAXIS_AI_IMAGE` to be set.

Required spike images:

1. `ghcr.io/nerdalert/maas-praxis-v3-praxis`
   - Praxis plus the Praxis AI changes used by this spike.
2. `ghcr.io/nerdalert/praxis-maas-authz-bridge@sha256:ab62af696f9e071f9edfcd1666b7d066ec330d80325d4ed18c89968d93767e0c`
   - Temporary Authorino/Limitador adapter used only by the demo.
3. `ghcr.io/nerdalert/maas-praxis-v3-provider-fixture`
   - Deterministic HTTPS ExternalModel Provider A/B fixture.
4. `ghcr.io/nerdalert/maas-praxis-v3-ai-gateway-controller`
   - Controller build containing the V3 spike changes needed by the demo.
5. `ghcr.io/nerdalert/maas-praxis-v3-runtime-reconciler`
   - Temporary in-cluster snapshot compiler. This replaces the current
     host-running reconciliation script for a portable demo and is not the
     intended product implementation.

Unmodified infrastructure images, including MaaS, Authorino, Limitador,
KServe, cert-manager, Istio, MetalLB, PostgreSQL, and the inference simulator,
should use their official registries and immutable digests. Do not republish
unchanged third-party images merely for convenience.

Every image variable must accept only a digest-pinned override. The demo must
print the final `name@sha256:digest` for each image and verify that the running
Pods use that digest. Tags may be used only as an operator input to resolve a
digest before deployment; they must never be the evidence or deployment form.

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

The portable runner delegates to the source-matched cold provisioner while
keeping the image input and run/cleanup boundary in this repository. These
commands are the reproducibility contract for the default Service path:

```bash
RUN_ID="maas-v3-$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="$PWD/evidence/$RUN_ID"
export PRAXIS_AI_IMAGE='<required digest-pinned Praxis AI image>'

# Deploy, qualify, write sanitized evidence, and clean up on success/failure.
./scripts/run-demo.sh \
  --run-id "$RUN_ID" \
  --praxis-ai-image "$PRAXIS_AI_IMAGE" \
  --authz-bridge-image 'ghcr.io/nerdalert/praxis-maas-authz-bridge@sha256:ab62af696f9e071f9edfcd1666b7d066ec330d80325d4ed18c89968d93767e0c' \
  --evidence-dir "$EVIDENCE_DIR"

# For diagnosis only: retain run-owned resources after a failure.
./scripts/run-demo.sh \
  --run-id "$RUN_ID" \
  --praxis-ai-image "$PRAXIS_AI_IMAGE" \
  --authz-bridge-image 'ghcr.io/nerdalert/praxis-maas-authz-bridge@sha256:ab62af696f9e071f9edfcd1666b7d066ec330d80325d4ed18c89968d93767e0c' \
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

## Source Repositories

Development forks required for the spike and its likely product path:

- [`nerdalert/praxis`](https://github.com/nerdalert/praxis)
- [`nerdalert/ai`](https://github.com/nerdalert/ai)
- [`nerdalert/ai-gateway-controller`](https://github.com/nerdalert/ai-gateway-controller)
- `nerdalert/ai-gateway-operator` (fork still required)
- [`nerdalert/models-as-a-service`](https://github.com/nerdalert/models-as-a-service)
- [`nerdalert/praxis-research-spikes`](https://github.com/nerdalert/praxis-research-spikes)

Keep KServe, Kuadrant Operator, Authorino, Limitador, cert-manager, Istio, and
MetalLB as pinned upstream dependencies unless the spike demonstrates a real
upstream change is necessary. Existing personal mirrors may be useful for
experimentation but are not required inputs to the reproducible demo.

The selected scheduler direction also treats
`llm-d/llm-d-inference-scheduler` and
`kubernetes-sigs/gateway-api-inference-extension` as pinned upstream
dependencies. Do not fork either repository unless qualification identifies a
specific defect that cannot be corrected in Praxis or its controller.

## Explicitly excluded from this demo

This qualification does not demonstrate InferencePool, EPP scheduling,
llm-d scheduling, or full-duplex llm-d ExtProc behavior. It does not add an
Envoy hop to either inference path. It also does not claim production parity
for the temporary authorization bridge, request-count quota versus token
reservation/settlement, real vLLM serving, OpenShift, or RHOAI. Those require
separate qualification and product work.
