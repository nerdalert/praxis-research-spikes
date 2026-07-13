# AI Grid gateway-to-gateway architecture

AI Grid is a federated inference routing architecture built around a simple
separation of concerns:

- the Grid control plane prepares routing state, identity, health, and peer
  state;
- Praxis gateways execute request-time routing locally;
- llm-d or another serving stack performs model execution and pod-level
  placement inside the selected provider site.

The request path is intentionally local and deterministic. A gateway does not
query Kubernetes, SWIM, Prometheus, or another control-plane service while a
client request is in flight. Those systems prepare state ahead of time; Praxis
reads the prepared snapshot and routes the request.

## Goals

The gateway-to-gateway architecture is designed to provide:

- one OpenAI-compatible request surface for clients;
- model routing across provider sites without exposing backend topology to
  applications;
- mutual TLS between gateways;
- provider-side peer identity enforcement;
- operator-generated routing overlays;
- health-aware and metrics-aware candidate ordering;
- peer-to-peer membership and provider-state distribution for decentralized
  grid operation.

## Components

### Consumer gateway

The consumer gateway is the client-facing Praxis AI gateway. It receives
OpenAI-compatible requests and selects a provider site for the requested model.

Responsibilities:

- accept client HTTP requests;
- extract the requested model from the request body;
- read the local grid routing snapshot;
- select a provider candidate;
- open an mTLS connection to the selected provider gateway;
- return the provider response to the client.

The consumer gateway is not a control-plane component. It does not reconcile
Kubernetes resources and does not perform remote discovery at request time.

### Provider gateway

The provider gateway is a Praxis AI gateway deployed near model-serving
capacity. It receives gateway-to-gateway traffic from consumer sites and
forwards accepted requests to the local serving path.

Responsibilities:

- terminate mTLS from peer gateways;
- expose verified peer identity to filters;
- reject untrusted peers before backend traffic is reached;
- call the External Processor path for llm-d-compatible endpoint selection;
- apply trusted endpoint mutations;
- proxy to the selected model backend.

### Grid Operator

The Grid Operator is the control-plane component. It watches Grid CRDs and
turns provider state into routing state for gateways.

Responsibilities:

- reconcile `GridNetwork`, `GridSite`, and `InferenceProvider` resources;
- classify provider health;
- scrape configured provider metrics;
- render routing overlay `ConfigMap`s;
- order candidates through the scoring engine;
- publish provider state to peers when SWIM is enabled;
- surface membership and distributed provider state in `GridNetwork` status.

The operator prepares state before requests arrive. Praxis consumes the
prepared overlay.

### SWIM and CRDT state plane

The peer-state plane gives Grid a decentralized mechanism for discovering live
sites and sharing provider records.

Responsibilities:

- exchange live membership through foca/SWIM UDP gossip;
- maintain a local membership snapshot;
- piggyback CRDT state broadcasts on SWIM traffic;
- merge remote provider snapshots into local distributed state;
- expose `connectedSites` and `distributedProviderCount` through
  `GridNetwork.status`.

SWIM and CRDT state are control-plane inputs. They are not consulted directly
by Praxis during a request.

### llm-d serving path

llm-d is the within-site inference scheduling layer. Grid selects the provider
site. The provider-side llm-d path selects the model endpoint or pod inside that
site.

In the current local validation environment, a deterministic mock External
Processor and inference simulator can stand in for the production llm-d Go EPP
and GPU workers.

## Request path

```text
Client
  -> Consumer Praxis gateway
  -> json_body_field extracts model
  -> grid_route selects provider candidate from local overlay
  -> mTLS connection to provider gateway
  -> Provider Praxis gateway
  -> grid_ingress_trust validates peer identity
  -> ext_proc streams request to EPP
  -> endpoint_selector applies trusted destination
  -> llm-d / inference backend
  -> OpenAI-compatible response
```

Request-time properties:

- model selection is driven by request content;
- provider selection is driven by local gateway config;
- trust is derived from the verified TLS peer certificate;
- endpoint selection headers from clients are not trusted;
- internal routing headers are stripped before proxying;
- the operator is not on the request path.

## Control-plane flow

The control plane prepares gateway-ready state.

```text
GridNetwork + InferenceProvider CRDs
  -> Grid Operator reconcile
  -> provider health probes
  -> optional metrics scrape
  -> scoring-backed candidate ordering
  -> routing overlay ConfigMap
  -> Praxis hot reload
  -> local request-time routing
```

The overlay is stored under the `grid-config.json` key in a
`grid-overlay-<network>-<gateway>` `ConfigMap`.

Example overlay:

```json
{
  "network": "op-e2e-net",
  "local_site": "consumer",
  "candidates": [
    {
      "kind": "inference_model",
      "name": "model-x",
      "site": "site-a",
      "cluster": "site-a",
      "fresh": true
    },
    {
      "kind": "inference_model",
      "name": "model-y",
      "site": "site-a",
      "cluster": "site-a",
      "fresh": false
    }
  ]
}
```

Candidate semantics:

- `kind` identifies the capability type;
- `name` is the model or capability name;
- `site` is the provider site identity;
- `cluster` is the routing cluster identity used by the gateway config;
- `fresh` indicates whether the provider is healthy enough to prefer.

`routingClusterRef` lets an `InferenceProvider` advertise a stable routing
identity that differs from its Kubernetes object name. This is the bridge
between operator-rendered candidates and Praxis load-balancer cluster names.

## Provider health

The operator maps provider state into routing candidates:

| Provider state | Overlay behavior |
| --- | --- |
| Healthy or reachable | Candidate appears with `fresh=true` |
| Degraded | Candidate appears with `fresh=false` |
| Unavailable | Candidate is excluded |

This keeps degraded capacity visible while preventing clearly invalid
providers from being offered to gateways.

## Metrics-aware ordering

`InferenceProvider.spec.metricsConfig` describes how the operator scrapes and
parses provider metrics.

Supported signal names include:

- queue depth;
- KV-cache utilization;
- p99 latency;
- prefix-cache hit ratio;
- error rate;
- healthy/unhealthy gauge.

The operator scrapes configured endpoints during `GridNetwork` reconcile,
maps Prometheus samples into scoring signals, and passes those signals into the
overlay renderer. Missing or malformed metrics fall back to neutral values so a
bad scrape does not remove a provider or produce non-finite scores.

In local validation, two metrics-serving providers expose different normalized
queue-depth values. The generated overlay ranks the low-queue provider ahead of
the high-queue provider.

## SWIM membership

Grid uses foca-backed SWIM gossip for peer membership. Each SWIM-enabled
operator has a site identity and UDP bind address. Seed peers allow a new site
to join the existing mesh.

Membership state feeds `GridNetwork.status`:

- an `Alive` peer contributes to `connectedSites`;
- `Suspect` and `Dead` peers do not contribute to `connectedSites`;
- at least one live peer can drive the network phase to `Active`;
- all known peers being unavailable can drive a degraded status.

The local validation path starts two out-of-cluster operator processes on
localhost UDP sockets. The secondary seeds the primary, real SWIM gossip
converges, and the reconciled `GridNetwork` reports `phase=Active` and
`connectedSites=1`.

## CRDT provider-state propagation

SWIM membership says which peers are alive. CRDT state says what those peers
offer.

Each operator maps local `InferenceProvider` resources into CRDT provider
records and publishes them through foca custom broadcast. Peers receive the UDP
gossip packet, merge the provider snapshot, and expose the remote record count
through `GridNetwork.status.distributedProviderCount`.

Provider fields propagated through CRDT state:

| CRDT field | Source |
| --- | --- |
| `network_id` | owning `GridNetwork.metadata.name` |
| `site_id` | local SWIM site identity |
| `provider_id` | `InferenceProvider.metadata.name` |
| `routing_cluster` | `spec.routingClusterRef` or metadata name |
| `models` | `spec.models[*].name` |
| `backend_kind` | `spec.backendKind` |
| `phase` | provider status phase |
| `metrics` | configured metrics scrape results when present |
| `revision` | resource version or generation |
| `writer_id` | local grid/site writer identity |

The distributed count is network-scoped. Local records and records from other
`GridNetwork`s are excluded. Local validation expects exactly one remote
provider record for the SWIM state fixture; a larger count indicates stale
state or cross-network leakage.

Distributed provider records are currently surfaced as state. The next routing
step is to consume those records as overlay candidate inputs.

## Trust model

Gateway trust is enforced in two layers.

TLS layer:

- clients without a certificate are rejected;
- certificates signed by an unknown CA are rejected;
- verified peer certificate material is exposed to the gateway context.

Application layer:

- `grid_ingress_trust` reads the verified peer identity;
- allowed organization or peer attributes are checked;
- same-CA but wrong-organization peers receive HTTP 403;
- accepted peers continue to the provider serving path.

This prevents cross-site routing from becoming a generic open tunnel.

## Praxis filter chains

Consumer gateway:

```text
json_body_field
  -> grid_route
  -> load_balancer
```

Provider gateway:

```text
grid_ingress_trust
  -> ext_proc
  -> endpoint_selector
  -> load_balancer / upstream proxy
```

The consumer chain chooses a site. The provider chain authenticates the peer
and delegates within-site endpoint selection to the EPP path.

## Local validation topology

The repeatable local environment uses kind clusters and out-of-cluster
operator processes.

Primary validation config:

- `site-a`: provider cluster with mock OpenAI backend and provider Praxis
  gateway;
- `consumer`: consumer cluster with Praxis gateway using the operator overlay;
- local operator process connected to the kind API server;
- optional local SWIM operator processes using localhost UDP sockets.

Core validation commands:

```console
cargo xtask env up -c tests/env/operator-routing.toml
cargo xtask env load-gateway-images -c tests/env/operator-routing.toml
cargo xtask env validate-operator-routing -c tests/env/operator-routing.toml
cargo xtask env verify-swim-membership -c tests/env/operator-routing.toml
cargo xtask env verify-swim-state -c tests/env/operator-routing.toml
cargo xtask env verify-mtls-trust -c tests/env/operator-routing.toml
cargo xtask env validate-all -c tests/env/operator-routing.toml
```

Validated behavior:

- CRDs generated from Rust types apply to kind;
- provider phases reconcile from live fixtures;
- unavailable providers are excluded;
- degraded providers are preserved with `fresh=false`;
- `routingClusterRef` drives overlay site and cluster identity;
- configured metrics change overlay ordering;
- operator-generated overlay drives consumer gateway traffic;
- known model requests return HTTP 200;
- unknown model requests fail cleanly;
- SWIM membership drives `phase=Active` and `connectedSites=1`;
- CRDT provider state propagates over SWIM with
  `distributedProviderCount=1`;
- mTLS positive and negative cases pass.

## Boundaries

The architecture intentionally separates what happens at request time from what
happens in the control plane.

Request-time path:

- read local config;
- route by model;
- enforce mTLS and peer trust;
- proxy to selected backend.

Control-plane path:

- reconcile CRDs;
- classify health;
- scrape metrics;
- score candidates;
- render overlays;
- exchange peer membership and provider state.

Current local validation proves the gateway path, trust path, operator overlay
path, metrics ordering path, SWIM membership path, and CRDT provider-state
path. Distributed CRDT records are visible to the operator but are not yet used
as routing candidates in the generated overlay.
