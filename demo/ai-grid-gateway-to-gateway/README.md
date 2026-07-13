# AI Grid gateway-to-gateway validation

This directory documents the AI Grid gateway-to-gateway validation path.

AI Grid lets a client call one OpenAI-compatible endpoint while the platform
routes the request to the provider site that can serve the requested model. The
consumer gateway chooses a provider from local routing state. The provider
gateway authenticates the peer, runs the llm-d-compatible endpoint-selection
path, and forwards to the selected backend.

## What this validates

The current validation stack proves:

- provider Praxis gateway request handling;
- consumer-to-provider gateway routing;
- mTLS peer authentication and ingress trust;
- Grid Operator CRD reconciliation;
- health-aware overlay generation;
- `routingClusterRef` identity bridging between Kubernetes providers and
  Praxis load-balancer clusters;
- configured metrics affecting candidate order;
- operator-generated overlay consumed by the consumer gateway;
- SWIM membership between operator peers;
- CRDT provider-state propagation over SWIM;
- clean failure for unknown models.

The gateway data plane is separate from the Grid control plane. Praxis makes
request-time decisions from local config; the operator prepares that config in
advance.

## Architecture

Read [architecture.md](architecture.md) for the complete control-plane,
data-plane, SWIM, CRDT, trust, and validation architecture.

Short version:

```text
Client
  -> Consumer Praxis gateway
  -> Provider Praxis gateway over mTLS
  -> ext_proc / endpoint_selector
  -> llm-d or inference backend
```

The operator path prepares state:

```text
Grid CRDs
  -> Grid Operator reconcile
  -> health and metrics state
  -> routing overlay ConfigMap
  -> Praxis hot reload
```

The peer-state path distributes state:

```text
SWIM membership
  -> live peer snapshot
  -> CRDT provider-state broadcast
  -> distributed provider snapshot
  -> GridNetwork status
```

## Primary validation commands

Run these from the Grid repository checkout.

One-time setup:

```console
cargo xtask env up -c tests/env/operator-routing.toml
cargo xtask env load-gateway-images -c tests/env/operator-routing.toml
```

Operator overlay and gateway routing:

```console
cargo xtask env validate-operator-routing -c tests/env/operator-routing.toml
```

SWIM membership:

```console
cargo xtask env verify-swim-membership -c tests/env/operator-routing.toml
```

CRDT provider-state propagation over SWIM:

```console
cargo xtask env verify-swim-state -c tests/env/operator-routing.toml
```

mTLS trust:

```console
cargo xtask env verify-mtls-trust -c tests/env/operator-routing.toml
```

All-in-one local validation:

```console
cargo xtask env validate-all -c tests/env/operator-routing.toml
```

CRD schema validation:

```console
cargo xtask env verify-crd-schema
```

## Expected evidence

The validation should show:

- provider and consumer kind clusters are reachable;
- Grid CRDs are installed;
- healthy, unavailable, degraded, API-fallback, and metrics provider fixtures
  reconcile to expected phases;
- unavailable providers are absent from the overlay;
- degraded providers appear with `fresh=false`;
- low-queue metrics provider ranks before high-queue metrics provider;
- overlay exports to a deterministic JSON path;
- consumer gateway deploys from the operator overlay;
- `model-x` returns HTTP 200 through the consumer gateway;
- unknown model returns a clean 404 or 503;
- SWIM membership reports `phase=Active` and `connectedSites=1`;
- CRDT state reports `distributedProviderCount=1`;
- mTLS rejects no-cert and wrong-CA clients;
- `grid_ingress_trust` rejects same-CA wrong-organization clients;
- valid gateway identity reaches the backend successfully.

## Repository roles

| Repository | Role |
| --- | --- |
| `praxis-proxy/grid` | Grid Operator, CRDs, scoring, certs, CRDT, SWIM, xtask validation |
| `praxis-proxy/ai` | Praxis AI gateway image, llm-d ext_proc compatibility, mock EPP |
| `praxis-proxy/praxis` | Core gateway filters and runtime behavior |
| `nerdalert/praxis-research-spikes` | Narrative and validation documentation |

## Important boundaries

This validation uses kind clusters and out-of-cluster operator processes. The
SWIM validations use localhost UDP sockets between local operator processes.

Validated:

- gateway-to-gateway routing;
- trust enforcement;
- operator-rendered overlay consumed by Praxis;
- configured metrics affecting overlay ordering;
- SWIM membership;
- CRDT provider-state propagation.

Not part of this validation:

- in-cluster operator Deployment and RBAC;
- production seed management;
- graceful SWIM leave on shutdown;
- distributed CRDT records as routing candidates;
- budget enforcement;
- dynamic MCP federation;
- real vLLM image validation.

## Related files

- [architecture.md](architecture.md) - complete architecture.
- [implementation-notes.md](implementation-notes.md) - implementation context and PR mapping.
- [upstream-pr-stack.md](upstream-pr-stack.md) - upstream PR stack overview.
- [demo-narrative.md](demo-narrative.md) - presentation narrative.
