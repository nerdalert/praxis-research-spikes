# Gateway-to-gateway connectivity, metadata, and routing proposal

## Status

This document is the consolidated proposal and implementation plan for
[praxis-proxy/praxis#664](https://github.com/praxis-proxy/praxis/issues/664),
"Gateway-to-Gateway Connectivity, Metadata and Routing".

It replaces the previous standalone research note under `research/` so the
gateway-to-gateway demo directory is the single public source for the proposal,
E2E evidence, and upstream PR split. The broader tracking issue is
[#690](https://github.com/praxis-proxy/praxis/issues/690); related scope
boundaries include the policy epic
[#678](https://github.com/praxis-proxy/praxis/issues/678) and the llm-d epic
[#16](https://github.com/praxis-proxy/praxis/issues/16).

## Summary

Epic 664 is about making Praxis gateways talk to each other safely.

Instead of every app knowing every model, tool, and agent endpoint, each site
runs a Praxis gateway. A local Praxis gateway can choose either:

- a local backend in its own cluster;
- a remote Praxis gateway at another site; or
- later, an external provider path owned by a different feature.

The key is that gateway-to-gateway traffic must be trusted, authenticated, and
easy to reason about. Praxis should use mutual TLS for gateway links, a compact
local map of known sites and capabilities, and a routing filter that chooses the
best allowed site without making a request-time call to Kubernetes, SWIM, or a
remote controller.

## Scope from Epic 664

Epic 664 asks for gateway-level primitives only:

| Epic requirement | In Praxis data plane | Outside this epic |
| --- | --- | --- |
| Egress connectivity to remote gateways | Remote gateway clusters, upstream mTLS, timeouts, health, and load-balancing | AI Grid Operator discovery and reconciliation |
| mTLS trust establishment | Listener mTLS for grid ingress, upstream mTLS for grid egress, peer identity exposure | Certificate issuance and lifecycle automation |
| Site descriptor registration | Typed local snapshot/config surface describing sites, capabilities, metrics, and epochs | AI Grid Operator reconciliation; SWIM/CRDT and Kubernetes are Operator inputs |
| Cross-gateway inference routing | Filter selects local or remote gateway cluster using request facts and snapshot candidates | llm-d worker scheduling inside the selected cluster |
| Cross-gateway agent routing | Reuse existing JSON-RPC/MCP/A2A classification metadata to choose remote agent/tool sites | Full agent policy model from #678 |

## Current Praxis facts that shape the plan

Praxis already has most of the proxy plumbing needed for this epic:

| Existing capability | Relevant files/docs | How it helps |
| --- | --- | --- |
| Filter pipeline with request/response phases | `praxis/filter/src/filter.rs`, `praxis/docs/architecture/overview.md` | A grid-routing filter can sit between protocol classification and load balancing. |
| Request context has `ctx.cluster` and `ctx.upstream` | `praxis/filter/src/context.rs` | The routing filter can select a cluster without owning connection code. |
| Existing load balancer owns endpoint selection | `praxis/filter/src/builtins/http/traffic_management/load_balancer/` | Grid routing should pick a site/provider cluster; load balancer should pick an endpoint. |
| Listener and upstream TLS already exist | `praxis/docs/operating/tls.md`, `praxis/tls/src/config/` | Gateway-to-gateway links can reuse existing rustls config surfaces. |
| Atomic hot reload exists | `praxis/docs/proposals/00011_dynamic-configuration-reloading.md` | Slow-changing remote gateway clusters and trust bundles can be rendered into config and reloaded safely. |
| AI and agent classifiers exist | `praxis/docs/architecture/ai-inference.md`, `praxis/docs/architecture/agentic-protocols.md` | Grid routing can consume extracted model, MCP, A2A, task, and method metadata. |
| Request-scoped typed extensions exist | `praxis/filter/src/extensions.rs` | More complex route decisions can use typed per-request state instead of stringly typed metadata. |
| Local state model proposal exists | `praxis/docs/proposals/00099_stateful-proxy-state-management.md` | The implementation should avoid raw global mutable state and define typed route-state APIs. |

The important gap is not "can Praxis proxy remote HTTP traffic?" It can. The
gap is a typed, trusted, grid-aware routing layer that decides which site or
gateway cluster to use, while preserving strict trust boundaries.

## Design goals

1. Keep the request path bounded and local.
2. Reuse existing cluster/TLS/load-balancer code for actual connections.
3. Make all route inputs typed, validated, freshness-bounded, and observable.
4. Treat mTLS identity, not client-supplied headers, as gateway trust.
5. Avoid putting Kubernetes, SWIM, Prometheus scraping, or CRDT merge logic
   inside the synchronous request path.
6. Make the first implementation useful with static configuration and a
   three-gateway demo.
7. Define the local snapshot contract the AI Grid Operator will publish.

## Possible implementation approach

Gateway-to-gateway routing should use a typed `grid_route` filter backed by an
immutable local `RoutingSnapshot`, while reusing existing Praxis clusters and
TLS for actual connectivity.

The `grid_route` filter reads existing request metadata and validated local
route state. It selects a local backend cluster or remote gateway cluster by
setting `ctx.cluster`. Existing Praxis load balancing, timeouts, TLS, and mTLS
continue to own the actual connection and endpoint selection.

The AI Grid Operator is responsible for rendering or updating the local gateway
snapshot outside the request path. Praxis consumes the latest accepted local
snapshot; it does not run global discovery and does not query the Operator,
Kubernetes, SWIM, CRDT peers, Prometheus, or a database while a client request
is waiting.

## Why this approach

| Consideration | Decision |
| --- | --- |
| Existing router-only routing | Useful for a manual smoke demo, but too weak for upstream AI Grid because it lacks typed site/capability state, freshness metadata, route-decision metadata, and a clean Operator integration contract. |
| Embedding SWIM/CRDT in Praxis | Wrong upstream boundary. Discovery, reconciliation, and liveness aggregation belong to the AI Grid Operator. Praxis should consume the rendered local snapshot. |
| Delegating baseline routing to `ext_proc` | Useful for specialized schedulers such as llm-d worker selection, but it adds a request-path network dependency and is not the right baseline for gateway-to-gateway site routing. |
| Typed immutable snapshot | Rust-friendly validation, cheap request-time reads, deterministic tests, bounded metadata, and clean PR boundaries. |
| Reusing existing Praxis clusters/TLS | Avoids rebuilding connectivity primitives. `grid_route` chooses the cluster; existing Praxis code connects to it. |

The design should split state into two channels:

| Channel | Update rate | Owner | Praxis mechanism |
| --- | --- | --- | --- |
| Connectivity and trust | Slow-changing | AI Grid Operator or static bootstrap config | Render ordinary clusters/listeners/TLS and use config hot reload. |
| Capabilities and metrics | Higher-churn | AI Grid Operator | Replace an immutable `RoutingSnapshot` atomically. |

This avoids hot-reloading the entire proxy for every capacity update, while
keeping all request-time decisions local and deterministic.

## Target architecture

Control/update path, outside request handling

```text
                     AI Grid Operator or static bootstrap
                                      |
                  +-------------------+-------------------+
                  |                                       |
                  | slow-changing connectivity/trust      | higher-churn route state
                  v                                       v
          Praxis config                         immutable RoutingSnapshot
          - listeners                           - sites
          - clusters                            - capabilities
          - TLS trust                           - freshness/capacity summaries
          - timeouts                            - policy/snapshot epochs
                  |                                       |
                  +-------------------+-------------------+
                                      |
                                      v
                         accepted local gateway state
```

Request path, per client transaction

```text
  Client / agent
      |
      v
  Praxis public listener
      |
      v
  protocol classifiers
      - OpenAI model metadata
      - MCP tool metadata
      - A2A metadata, once route semantics are defined
      |
      v
  grid_route
      - reads request metadata
      - reads latest accepted RoutingSnapshot
      - selects ctx.cluster only
      |
      +-------------------------------+
      |                               |
      v                               v
  local Praxis cluster           remote gateway cluster
      |                               |
      v                               v
  load_balancer                  upstream mTLS
      |                               |
      v                               v
  local backend / llm-d          destination Praxis grid listener
                                  - validates mTLS peer identity
                                  - applies grid ingress trust
                                  - routes to destination-local backend / llm-d
```

For remote gateway traffic:

```text
origin workload
  -> origin Praxis public listener
  -> request classification + policy
  -> grid_route selects remote-site-b gateway cluster
  -> upstream mTLS to destination Praxis grid listener
  -> destination validates mTLS peer identity and gateway route context
  -> destination applies local policy and routes to local inference/tool/agent
```

## Core data model

The exact Rust names can change, but the implementation should converge on
these concepts.

| Type | Purpose | Notes |
| --- | --- | --- |
| `SiteId` | Stable grid site identifier | Newtype over bounded string; not a raw `String` in scoring code. |
| `CapabilityId` | Stable advertised capability identifier | Lets metrics and route decisions reference a concrete advertised service. |
| `CapabilityKind` | `inference`, `mcp_tool`, `a2a_agent`, later others | Enum, not string. |
| `BackendClass` | `local_cluster`, `remote_gateway`, `external_provider` | External providers may be represented later, but are not grid peers. |
| `GatewayEndpoint` | Remote gateway cluster name and expected TLS identity | The cluster name must exist in config. |
| `CapabilityDescriptor` | Model/tool/agent capability, feature flags, region, cost class, labels | Bounded maps/lists only. No secrets. |
| `CapacitySummary` | Freshness-bounded score inputs such as health, queue pressure, latency, capacity | Must include timestamp/expiry and stale behavior. |
| `RoutingSnapshot` | Immutable generation of all sites/capabilities/capacity summaries | Held behind `ArcSwap`; request reads one generation. |
| `RouteDecision` | Selected site, capability, cluster, reason, snapshot generation | Stored in typed request extension plus safe metadata for logs. |

Do not use the existing raw `KvBackend` as the primary route-state API. It is a
runtime string cache, not a typed domain model. It may remain useful for admin
debugging or temporary overrides, but the grid route code should use typed
snapshot structures.

## `grid_route` filter behavior

The first upstreamable filter should be deterministic and local.

### Inputs

| Input source | Example |
| --- | --- |
| Existing AI inference filters | model name, OpenAI format, stream mode, requested features |
| Existing MCP filter | tool name, method, protocol version, session presence |
| Existing A2A filter | method, family, task ID, streaming flag |
| Trusted identity/policy metadata | tenant, agent, caller identity, allowed classes; initially static or provided by later policy filter |
| `RoutingSnapshot` | candidate sites, capabilities, capacity summaries, config generation |

### Output

| Output | Purpose |
| --- | --- |
| `ctx.cluster` | Selects local backend cluster or remote gateway cluster. |
| Typed `RouteDecision` extension | Lets later filters and response logging see the selected route without parsing strings. |
| Safe metadata | Snapshot generation, selected site, capability ID, and decision reason for logs/metrics. |
| Optional gateway-to-gateway forwarding context | Future contract for making route context visible to the destination gateway; must be generated by Praxis and stripped/validated at trust boundaries. |

### Non-goals

- Opening network connections in `grid_route`.
- Calling Kubernetes, Prometheus, SWIM, or a remote scheduler from the request
  path.
- Owning worker/pod selection inside llm-d.
- Gossiping or storing provider credentials.
- Replaying requests after bytes may have reached a backend.

## mTLS and trust design

Praxis already supports listener mTLS and upstream mTLS. Epic 664 needs one
missing capability: filters must be able to know the authenticated gateway peer
identity on grid ingress.

| Need | Existing support | Required implementation |
| --- | --- | --- |
| Origin connects to destination gateway with client cert | `ClusterTls.client_cert` | Use existing upstream mTLS config. |
| Destination requires client cert | `ListenerTls.client_cert_mode: require` | Use existing listener mTLS config. |
| Destination authorizes a specific grid peer | Partial | Expose verified peer certificate identity in `HttpFilterContext`. |
| Gateway route context is trusted only from grid peers | Not enough today | Strip public client-supplied grid context and validate any gateway-owned forwarding context only on mTLS-authenticated grid listeners. |

Recommended identity model:

1. Start with SPIFFE URI SAN or DNS SAN matching as the preferred identity
   source.
2. Represent peer identity as a typed `TlsPeerIdentity` in request context.
3. Add config that maps expected peer identity to a `SiteId`.
4. Reject grid ingress if the mTLS certificate is absent, unverified, expired,
   or not mapped to a known site.

If Pingora/rustls integration cannot expose the full certificate chain easily,
the first PR should still add the context shape and tests around the adapter
boundary, then wire actual extraction in the protocol layer as a focused
follow-up.

## Site descriptor registration

For Epic 664, "registration" should mean "Praxis can consume a validated local
snapshot of site descriptors", not "Praxis runs global discovery".

### Initial static shape

```yaml
filter: grid_route
snapshot:
  generation: "demo-1"
  sites:
    - id: site-a
      locality:
        region: us-east
        zone: local
      gateway:
        cluster: grid-site-a
        expected_identity: spiffe://ai-grid/site-a/praxis
      capabilities:
        - id: llama-local-chat
          kind: inference
          model: llama-3.1-8b
          cluster: local-llmd
          freshness_ms: 10000
          score:
            base: 100
```

### Later operator-fed shape

The operator should produce the same validated `RoutingSnapshot`, either by:

1. rendering a local file that Praxis watches and atomically loads; or
2. calling a local admin endpoint that replaces the snapshot; or
3. building a custom Praxis binary with an in-process snapshot publisher.

Direct Kubernetes watches belong in the Operator, not the Praxis gateway.

## Scoring model

The first scorer should be intentionally simple and explainable.

| Score input | Initial behavior |
| --- | --- |
| Capability match | Required. Wrong kind/model/tool/agent is ineligible. |
| Policy allowance | Required when policy metadata exists; otherwise demo mode can use explicit allow-all config. |
| Site liveness | Required for remote sites. Stale or missing liveness makes a remote site ineligible. |
| Capacity freshness | Penalize stale capacity; reject only if configured as required. |
| Locality | Prefer local site, then same region, then remote region. |
| Cost/tier | Static additive or subtractive score. |
| Session/task affinity | If a valid binding exists, prefer or require that site depending on config. |

Keep the first scoring implementation intentionally small. The route decision must be
auditable: "selected site-b because it was eligible, fresh, same region, and
had the highest score" is better than a complex opaque ranking formula.

### Scoring boundary with llm-d

`grid_route` scoring is gateway-level scoring. It should decide which Praxis
cluster receives the request: a local inference cluster, a remote gateway
cluster, a tool cluster, or later another supported target class.

It should not choose a GPU pod, model worker, or llm-d endpoint. After
`grid_route` sets `ctx.cluster`, existing Praxis load balancing and any
downstream llm-d/EPP integration still decide where the workload lands inside
the selected cluster or site.

This keeps the layers separate:

| Layer | Decision |
| --- | --- |
| AI Grid / `grid_route` | Which site, gateway, or Praxis cluster should receive this request? |
| Praxis load balancer | Which endpoint in the selected cluster should receive the HTTP request? |
| llm-d / EPP | Which local inference worker or pod should run the model request? |

The scoring inputs can include coarse site-level signals such as freshness,
locality, or capacity summary, but they should not duplicate llm-d's
fine-grained worker scheduling.

## Inference routing path

```text
OpenAI-compatible request
  -> model/body classifier
  -> grid_route builds inference candidates
  -> local site selected:
       ctx.cluster = local inference cluster
       local llm-d/EPP can choose worker later
  -> remote site selected:
       ctx.cluster = remote gateway cluster
       record bounded route metadata
  -> load_balancer picks endpoint
  -> upstream mTLS or local cluster
```

llm-d remains local-worker selection. AI Grid should choose the site and
inference pool; llm-d should choose a pod/worker inside the selected local
site. This keeps issue #664 aligned with issue #16 instead of competing with it.

## Agent routing path

```text
MCP or A2A request
  -> json_rpc/mcp/a2a classifier
  -> grid_route builds tool/agent candidates
  -> policy removes forbidden targets
  -> scorer chooses local or remote gateway cluster
  -> destination gateway validates origin mTLS and routes locally
```

Existing A2A task routing is local-only and uses an in-process TTL map. Epic
664 should not quietly claim global task ownership. The first cross-gateway
agent demo should route by static agent/tool capability. A later task can add a
typed, TTL-backed task/session binding model that is explicit about local-only
versus shared semantics.

## Security rules

| Rule | Reason |
| --- | --- |
| Public listeners must strip all `X-Praxis-Grid-*` internal headers before routing. | A client must not be able to impersonate a gateway or force a route. |
| Grid listeners must require mTLS. | Remote gateway traffic is privileged. |
| Peer identity must map to a known `SiteId`. | A valid certificate alone is not enough if it is not an authorized grid peer. |
| Destination gateway must re-check local policy. | Origin policy may be stale or less strict than destination policy. |
| Site descriptors must not contain credentials. | Discovery state is replicated; secrets belong in local secret management. |
| Unknown, malformed, or stale trust data must reject. | Trust failures are not capacity failures. |
| Route decisions must include snapshot generation. | Auditing and debugging require knowing which local view made the decision. |

## PR-sized implementation plan

### 664-00: planning and child issue breakdown

Create the upstream proposal/design issue material and split this epic into
child issues. No production code.

Acceptance:

- child issues exist for TLS peer identity, grid snapshot model, grid route
  filter, remote ingress trust, inference demo, agent demo, and docs;
- scope explicitly excludes SWIM/CRDT/operator implementation.

### 664-01: expose downstream mTLS peer identity

Add a transport-level context field for verified downstream TLS peer identity.

Implementation notes:

- add a typed identity struct in `praxis-tls` or `praxis-core`;
- populate it in the HTTP protocol adapter when a listener requests/requires
  client certificates;
- keep it optional for non-mTLS listeners;
- do not parse authorization policy in the TLS layer.

Tests:

- unit tests for identity parsing from SAN/CN test certificates;
- integration/conformance test for mTLS listener identity exposure;
- negative tests for no cert and unmapped identity.

### 664-02: grid ingress trust filter

Add a small filter that establishes whether the request is from a trusted grid
peer and strips or validates internal grid headers.

Implementation notes:

- public mode: strip `X-Praxis-Grid-*`;
- grid ingress mode: require peer identity and map it to `SiteId`;
- write trusted origin site into typed extension/metadata;
- reject malformed internal headers.

Tests:

- client-supplied internal header stripped on public listener;
- grid listener rejects without mTLS identity;
- grid listener accepts mapped peer;
- grid listener rejects mismatched peer/header site.

### 664-03: typed routing snapshot model

Add typed config/model structures for site descriptors, capabilities, capacity
summaries, and snapshot generation.

Implementation notes:

- use bounded newtypes for IDs;
- use enums for capability kind and backend class;
- reject unknown fields;
- validate remote gateway clusters exist;
- validate expiry/freshness budgets;
- keep secrets out of the schema.

Tests:

- parse valid static snapshot;
- reject unknown fields, empty IDs, duplicate IDs, impossible freshness, missing
  cluster references, and unsupported capability combinations;
- snapshot clone/load is cheap enough for request path.

### 664-04: `grid_route` filter, inference first

Implement deterministic candidate selection for inference requests.

Implementation notes:

- consume existing model/format metadata when available;
- support explicit static capability matching for model name;
- select `ctx.cluster`, not `ctx.upstream`;
- store `RouteDecision` in typed request extensions;
- emit safe metadata for logs and metrics.

Tests:

- local candidate selected;
- remote candidate selected;
- stale remote site skipped;
- no eligible candidate returns configured status;
- score tie-break is deterministic;
- existing `load_balancer` forwards to the selected cluster.

### 664-05: remote gateway forwarding contract

Define the gateway-to-gateway forwarding metadata contract and verify
destination behavior.

Implementation notes:

- record bounded gateway-owned route context only after a trusted route
  decision;
- include origin site, selected capability, snapshot generation, and route ID
  if that context is forwarded across a gateway boundary;
- destination validates origin identity and forwarding context before using it;
- strip gateway-owned context before sending to final non-grid backend unless
  explicitly allowed.

Tests:

- origin records route context only for successful route decisions;
- destination accepts valid mTLS and gateway-owned route context;
- destination rejects spoofed or mismatched context;
- final backend does not receive gateway-owned context by default.

### 664-06: capacity/freshness-aware scoring

Extend scoring beyond static capability matches.

Implementation notes:

- implement small additive scoring with documented weights;
- include freshness penalties and stale-data behavior;
- add local preference and same-region preference;
- no request-derived high-cardinality labels or logs.

Tests:

- stale metrics penalized or rejected according to config;
- local preference works;
- healthier remote site wins when local is overloaded;
- decision metadata explains the selected route.

### 664-07: MCP/A2A static capability routing

Extend `grid_route` candidate building to existing MCP and A2A metadata.

Implementation notes:

- MCP: route by tool name/method/capability;
- A2A: route by agent capability/method family;
- no global task ownership claim in this PR;
- include clear examples.

Tests:

- local MCP tool route;
- remote MCP tool route;
- local A2A agent route;
- remote A2A agent route;
- unknown tool/agent rejected or falls back according to explicit config.

### 664-08: three-gateway inference demo

Create an integration/demo harness with three Praxis gateways and local mock
inference backends.

Acceptance:

- request to site A can route locally, to site B, and to site C based on static
  capabilities and freshness;
- gateway-to-gateway path uses mTLS;
- spoofed internal headers fail;
- all logs are sanitized.

### 664-09: three-gateway agent demo

Extend the demo to MCP/A2A traffic.

Acceptance:

- agent-to-tool route across gateway boundary;
- agent-to-agent route across gateway boundary;
- agent-to-inference route across gateway boundary;
- destination gateway re-checks trust.

### 664-10: docs, examples, and benchmarks

Finish upstream quality requirements.

Required:

- filter docs generated;
- example configs in `examples/configs/`;
- `examples/README.md` updated;
- functional example integration tests;
- benchmark note or microbenchmark for scorer/snapshot read overhead;
- operations doc for gateway-to-gateway TLS.

## Child issues to open

| Issue | Title | Size |
| --- | --- | --- |
| 664-A | Expose verified downstream mTLS peer identity to HTTP filters | Medium |
| 664-B | Add grid ingress trust filter and internal-header stripping | Medium |
| 664-C | Add typed AI Grid routing snapshot schema | Medium |
| 664-D | Add inference-capable `grid_route` filter | Large |
| 664-E | Add gateway-to-gateway internal forwarding contract | Medium |
| 664-F | Add freshness/locality/capacity scoring | Medium |
| 664-G | Add MCP/A2A static capability routing | Medium |
| 664-H | Add three-gateway P2P inference demo and tests | Large |
| 664-I | Add three-gateway P2P agent demo and tests | Large |
| 664-J | Add docs, examples, and benchmark evidence | Medium |

## Dependencies and sequencing

```text
664-00 planning
  |
  +--> 664-01 mTLS peer identity
  |       |
  |       v
  |   664-02 ingress trust
  |
  +--> 664-03 routing snapshot schema
          |
          v
      664-04 grid_route inference
          |
          +--> 664-05 remote forwarding contract
          |       |
          |       v
          |   664-08 P2P inference demo
          |
          +--> 664-06 scoring
          |
          +--> 664-07 MCP/A2A routing
                  |
                  v
              664-09 P2P agent demo

664-10 docs/examples/benchmarks lands across or after the implementation PRs.
```

## Main risks

| Risk | Mitigation |
| --- | --- |
| Treating stale grid state as truth | Every capacity/capability record carries generation and expiry; scorer penalizes or rejects stale records. |
| Header spoofing | Public listener strips internal headers; grid listener accepts them only with mapped mTLS peer identity. |
| Hot-reloading too often | Use config reload for slow connectivity/trust and atomic snapshots for high-churn capacity. |
| Overbuilding scoring | Start with deterministic, explainable score inputs and add complexity only when tests require it. |
| Coupling Praxis to the Operator | Define a local snapshot contract; keep SWIM/CRDT/Kubernetes code outside Praxis. |
| Confusing grid routing with llm-d scheduling | Grid selects site/pool/gateway; llm-d selects local worker after a local site is chosen. |
| Global A2A task ownership hidden in local maps | First agent demo routes static capabilities only; task/session ownership gets a separate typed-store design. |

## Open questions before coding

These should be answered or explicitly deferred in child issues:

1. What exact gateway peer identity format should be authoritative: SPIFFE URI
   SAN, DNS SAN, certificate subject, or a configured matcher list?
2. What should the first Operator publication mechanism be: rendered file
   watched by Praxis, local admin endpoint, or in-process snapshot publisher?
3. What is the initial policy contract with #678: allow-all demo mode, static
   allow lists, or a real deny-by-default filter dependency?
4. What exact normal Praxis cluster config should the Operator render for
   remote gateways, and how should `RoutingSnapshot` validate references to
   those clusters?
5. For streaming inference and A2A SSE, when is failover allowed? The safe
   default should be no replay after upstream selection.
6. What route decision fields are required for audit and billing consumers?
7. Should external providers appear in the same `RoutingSnapshot` as
   non-peer `external_provider` candidates, or remain outside Epic 664?

## Best first engineering slice

The most useful first slice is:

1. mTLS peer identity exposure;
2. ingress trust/internal-header stripping;
3. static typed snapshot schema;
4. `grid_route` inference candidate selection;
5. one three-gateway local integration test with mock backends.

That proves the hard trust boundary and the data-plane shape before building
the AI Grid Operator publication path, SWIM/CRDT inputs, llm-d integration, or
full policy integration.

## References

- [Epic 664: Gateway-to-Gateway Connectivity, Metadata and Routing](https://github.com/praxis-proxy/praxis/issues/664)
- [Epic 690: AI Grid Capabilities](https://github.com/praxis-proxy/praxis/issues/690)
- [Epic 678: Policy Engine](https://github.com/praxis-proxy/praxis/issues/678)
- [Epic 16: llm-d](https://github.com/praxis-proxy/praxis/issues/16)
- [Rust API Guidelines: type safety](https://rust-lang.github.io/api-guidelines/type-safety.html)
- [Serde container attributes](https://serde.rs/container-attrs.html)
- [Tokio shared state tutorial](https://tokio.rs/tokio/tutorial/shared-state)
- [arc-swap crate docs](https://docs.rs/arc-swap/latest/arc_swap/)
- [rustls crate docs](https://docs.rs/rustls/latest/rustls/)
