# MaaS/Praxis V3 Dataplane Demo

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

Praxis is the tenant-facing proxy and final-hop client. The selected request
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

Required spike images:

1. `ghcr.io/nerdalert/maas-praxis-v3-praxis`
   - Praxis plus the Praxis AI changes used by this spike.
2. `ghcr.io/nerdalert/maas-praxis-v3-authz-bridge`
   - Temporary Authorino/Limitador adapter used only by the demo.
3. `ghcr.io/nerdalert/maas-praxis-v3-provider-fixture`
   - Deterministic HTTPS ExternalModel Provider A/B fixture.
4. `ghcr.io/nerdalert/maas-praxis-v3-ai-gateway-controller`
   - Controller build containing the V3 spike changes needed by the demo.
5. `ghcr.io/nerdalert/maas-praxis-v3-runtime-reconciler`
   - Temporary in-cluster snapshot compiler. This replaces the current
     host-running reconciliation script for a portable demo and is not the
     intended product implementation.

The primary InferencePool scheduler is the unmodified upstream llm-d inference
scheduler. Pin its published image by digest; do not republish it under the
demo namespace. The earlier modified LWEPP remains historical/optional fixture
material and is not a required image for this demo.

Unmodified infrastructure images, including MaaS, Authorino, Limitador,
KServe, cert-manager, Istio, MetalLB, PostgreSQL, and the inference simulator,
should use their official registries and immutable digests. Do not republish
unchanged third-party images merely for convenience.

Every image variable must accept a digest-pinned override. Default demo values
may use a release tag for readability only when the scripts resolve and record
the immutable digest before deployment.

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
