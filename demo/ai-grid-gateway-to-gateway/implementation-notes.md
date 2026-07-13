# AI Grid — Implementation Notes

## Repositories

| Repository | Role | Branch / state |
| --- | --- | --- |
| `praxis-proxy/grid` | Operator, xtask, certs, scoring, CRDTs | `main` + extraction branches |
| `praxis-proxy/ai` | Praxis AI gateway, llm-d ext_proc, mock EPP | `llmd-ext-proc` build |
| `praxis-proxy/praxis` | Gateway core, `grid_route`, `grid_ingress_trust` | extraction branches |
| `nerdalert/praxis-research-spikes` | Demo assets (this repo) | `codex/gateway-to-gateway-demo` |

---

## What AI Grid is

AI Grid is a federated AI data plane. It routes inference requests and agent
workloads across clusters, providers, and sites using local routing snapshots
and mutual TLS for gateway identity. The Grid Operator prepares those snapshots
in the background; the gateway reads them at request time without querying any
control-plane system.

**Plain-language summary:** a client sends one OpenAI-compatible request to a
consumer gateway. The gateway reads a local table, picks the provider site that
hosts the model, and forwards the request over mTLS. The provider gateway
enforces peer identity and routes to a backend. The client never knows which
cluster served the request.

---

## Architecture layers

```text
┌─────────────────────────────────────────────────────────┐
│  Control plane — Grid Operator                          │
│  watches GridNetwork, GridSite, InferenceProvider CRDs  │
│  renders RoutingOverlay ConfigMaps per gateway           │
│  manages mTLS certificate material                      │
│  future: SWIM/CRDT health aggregation                   │
└───────────────────────┬─────────────────────────────────┘
                        │ ConfigMap: grid-overlay-<network>-<gateway>
                        │ key: grid-config.json
                        ▼
┌─────────────────────────────────────────────────────────┐
│  Data plane — Praxis AI gateway                         │
│  json_body_field  extracts model → X-Model header        │
│  grid_route       reads local snapshot, selects cluster  │
│  grid_ingress_trust enforces peer identity at providers  │
│  ext_proc         full-duplex gRPC stream to EPP         │
│  endpoint_selector routes to per-model backend           │
└───────────────────────┬─────────────────────────────────┘
                        │ HTTP/mTLS
                        ▼
┌─────────────────────────────────────────────────────────┐
│  Serving plane — llm-d / inference-sim                  │
│  per-model endpoints                                     │
│  health and metrics surface (future: Prometheus/vLLM)   │
└─────────────────────────────────────────────────────────┘
```

**Summary:** Three layers with clean separation. The Operator owns topology and
policy; it publishes snapshots outside the request path. Praxis AI owns the
data-plane decision and enforces trust. llm-d or inference-sim owns per-model
scheduling.

---

## Three-cluster demo topology

```text
                   cluster-a  (provider)
                   ┌────────────────────────────────────────┐
                   │  Praxis AI (provider gateway)          │
                   │  ← ext_proc → mock EPP                 │
                   │  inference-sim: granite-3.3-8b          │
                   │                mistral-7b              │
                   └───────────────────────┬────────────────┘
                                           │ mTLS
client → cluster-c (consumer) ────────────┤
         Praxis AI                         │ mTLS
         grid_route                        │
         json_body_field                   │
                   cluster-b  (provider)   │
                   ┌────────────────────────────────────────┐
                   │  Praxis AI (provider gateway)          │
                   │  ← ext_proc → mock EPP                 │
                   │  inference-sim: llama-3.2-8b           │
                   └────────────────────────────────────────┘
```

| Cluster | Role | Models |
| --- | --- | --- |
| cluster-a | Provider | granite-3.3-8b, mistral-7b |
| cluster-b | Provider | llama-3.2-8b |
| cluster-c | Consumer | — (routes only) |

---

## Request path — step by step

**Summary:** Every routing decision is local. No control-plane call happens
while the client is waiting. The entire path from client to backend and back is
deterministic from the state present at the start of the request.

**Technical flow:**

```text
1.  Client → POST /v1/chat/completions  { "model": "granite-3.3-8b", ... }
             (or POST /v1/responses for the Responses API path)

2.  Consumer gateway (cluster-c)
    a. json_body_field extracts top-level "model" field → X-Model: granite-3.3-8b
    b. grid_route reads local candidate list from config/overlay
    c. grid_route scores candidates (locality, freshness)
    d. grid_route sets ctx.cluster = "gateway-cluster-a"
    e. Praxis opens mTLS connection to cluster-a provider gateway

3.  Provider gateway (cluster-a)
    a. grid_ingress_trust reads verified TLS peer identity
    b. Checks OrganizationName against trusted peer list (demo: "ai-grid")
    c. Same-CA wrong-org → HTTP 403; unknown CA → TLS failure
    d. Accepted → ext_proc opens full-duplex gRPC stream to mock EPP
    e. Mock EPP selects per-model inference-sim endpoint
    f. endpoint_selector validates trusted mutation, sets ctx.upstream
    g. endpoint_selector strips internal routing header
    h. Praxis forwards to inference-sim

4.  inference-sim → HTTP 200 chat completions JSON

5.  Response: inference-sim → provider gw → consumer gw → client
```

---

## Integration with llm-d

**Summary:** llm-d is the local inference scheduling layer. In the demo,
`llm-d-inference-sim` stands in for real GPU workers. The AI Grid gateway sits
in front of llm-d scheduling via the ext_proc / EPP path; the Grid itself
routes at the site/cluster level, then hands off to llm-d for within-cluster
placement.

**Technical flow:**

```text
Praxis AI gateway
  ↓
ext_proc filter (full-duplex gRPC, Envoy-compatible)
  ↓
Mock EPP (praxis-ai-mock-epp image)
  — in production: llm-d Go EPP (endpoint picker)
  — selects per-model endpoint via x-gateway-destination-endpoint header mutation
  ↓
endpoint_selector filter
  — validates the mutation came from the trusted EPP, not the client
  — sets ctx.upstream to the selected endpoint
  — strips the internal routing header
  ↓
inference-sim (or real llm-d GPU worker)
```

The `ext_proc` stream is full-duplex: headers and body flow incrementally. The
EPP responds with an endpoint mutation before the body is fully received. This
matches the llm-d production path where the EPP may need the model name
(extracted from the request body) to pick a KV-cache-aware worker.

**What mock EPP does vs production EPP:**

| Property | Mock EPP | llm-d Go EPP |
| --- | --- | --- |
| Endpoint selection | Static per-model map | KV-cache, queue depth, prefix cache |
| Protocol | Envoy ext_proc (full-duplex) | Envoy ext_proc (full-duplex) |
| Health awareness | None | Prometheus/vLLM metrics |
| Scheduling | None | LWS, rank-aware, SPMD |

---

## Integration with Praxis

**Summary:** Praxis AI is the data-plane proxy. It extends Praxis core with
AI-specific filters. The Grid uses three filters from Praxis:
`json_body_field` (model extraction), `grid_route` (site selection), and
`grid_ingress_trust` (peer identity enforcement). These sit alongside the
generic `ext_proc` and `endpoint_selector` filters already in Praxis core.

**Filter pipeline (consumer gateway):**

```yaml
filters:
  - filter: json_body_field      # extract "model" → X-Model header
    field: model
    header: x-model
  - filter: grid_route           # select cluster from local snapshot
    local_site: cluster-c
    model_header: x-model
    candidates: [...]
```

**Filter pipeline (provider gateway):**

```yaml
filters:
  - filter: grid_ingress_trust   # enforce peer identity
    trusted_peers:
      - organization: ai-grid
  - filter: ext_proc             # call mock EPP / llm-d EPP
    target: grpc://mock-epp:9002
    processing_mode:
      request_body_mode: full_duplex_streamed
  - filter: endpoint_selector    # apply EPP endpoint mutation
    source_header: x-gateway-destination-endpoint
    required: true
    strip_header: true
```

**Key Praxis design points:**

| Property | Behavior |
| --- | --- |
| Request-time routing | Reads local config only — no Kubernetes, SWIM, or database call |
| Hot reload | Atomic file-watcher swap, 500ms debounce |
| In-flight isolation | In-flight requests finish on previous pipeline after reload |
| Peer identity | Derived from verified TLS session (`SslDigest`), not request headers |
| Header spoofing | Public `x-praxis-*` headers rejected before any filter sees them |

---

## Routing overlay

**Summary:** The overlay is the contract between the Grid Operator and the
consumer gateway. The Operator writes it; the gateway reads it. The document
format is stable and tested independently of a live Operator.

**Wire format** (`grid-config.json` stored in a ConfigMap key):

```json
{
  "network": "ai-grid-demo",
  "local_site": "cluster-c",
  "candidates": [
    {
      "kind": "inference_model",
      "name": "granite-3.3-8b",
      "site": "cluster-a",
      "cluster": "provider-a",
      "fresh": true
    },
    {
      "kind": "inference_model",
      "name": "llama-3.2-8b",
      "site": "cluster-b",
      "cluster": "provider-b",
      "fresh": true
    }
  ]
}
```

**ConfigMap name:** `grid-overlay-<network>-<gateway>`
Written by the Operator via server-side apply into the consumer namespace.

**Candidate scoring (static demo):**

| Signal | Score delta |
| --- | --- |
| fresh = true | 0 |
| fresh = false | −100 |
| local site | +10 |
| equal score | first configured candidate wins |

**Demo bridge:** The xtask reads a local `grid-config.json` file via
`--overlay-config` and converts it to Praxis YAML using `gateway-{site}` as
the cluster reference. The wire format is identical to what the Operator writes.
No live Operator is required to prove the routing behavior.

---

## Trust and mTLS model

**Summary:** Trust is enforced at three layers. The demo uses generated certs
with `O=ai-grid`. In production, SPIFFE/SPIRE SVIDs replace the
OrganizationName check.

**Three enforcement layers:**

| Layer | Mechanism | Failure mode |
| --- | --- | --- |
| TLS | Provider gateway requires client cert | No cert → TLS handshake fails |
| PKI | Cert chain validated against Grid CA | Unknown CA → TLS handshake fails |
| Filter | `grid_ingress_trust` checks OrganizationName | Wrong org → HTTP 403 |

**Certificate generation (demo):**

```text
cargo xtask env up
  → generate_ca()             creates grid CA (PEM + key)
  → generate_site_cert()      creates per-cluster cert signed by CA
  → generate_cert_with_org()  creates wrong-org cert (O=not-ai-grid)
                              used by verify-mtls-trust negative case
```

The `DEMO_ORGANIZATION` constant (`"ai-grid"`) must match the value configured
in the `grid_ingress_trust` filter on every provider gateway.

**Known limitation:** The same-CA wrong-org assertion fails on one cluster
roughly 1 in 10 runs in kind due to port-forward timing. The filter is correct;
the flake is in the test harness.

---

## Grid Operator

**Summary:** The operator reconciles CRDs into routing snapshots. It is
independent of the Praxis data-plane and produces the overlay JSON that the
gateway consumes. Three PRs are extraction-ready.

**Implemented (PR-ready):**

| PR | What it does |
| --- | --- |
| OPERATOR-01 | Renders `RoutingOverlay` ConfigMaps from GridNetwork + GridSite + InferenceProvider. Locality-ordered, freshness-tagged candidates. 56 tests. |
| OPERATOR-02 | Reconciles `InferenceProvider` status: validates config, resolves matching GridSites, sets `phase` and `matchingSites`. 14 tests. |
| OPERATOR-03 | Bridge: converts `RoutingOverlay` → Praxis `grid_route` JSON stanza. 11 tests. |

**CRD structure:**

```
GridNetwork        — defines a grid domain (name, CA ref, gateway refs)
  └── GatewayRef  — per-gateway local_site name for overlay rendering

GridSite           — represents a peer site (phase, capabilities, address)

InferenceProvider  — declares a model-serving provider (endpoint, models,
                     siteSelector, healthCheck, status.phase)
```

**Health decision model** (OP-02, implemented):

| Condition | Phase |
| --- | --- |
| Blank endpoint or model name | Unavailable |
| GridNetwork not found | Unavailable |
| Config valid, probe transport failure | Unavailable |
| Config valid, probe HTTP non-2xx | Degraded |
| Config valid, healthy probe, no matching sites | Pending |
| Config valid, healthy probe, ≥1 matching site | Available |

**Not yet wired:**
- Live HTTP health probe loop (OP-05)
- Gateway annotation patching (target object type TBD)
- Direct ConfigMap fetch in xtask (demo reads local file)
- SWIM/CRDT state propagation into overlay freshness

---

## Scoring engine

**Summary:** The scoring engine ranks candidate backends using six weighted
signals. It is implemented in the `scoring` crate, independent of Kubernetes.

**Signals and weights (defaults):**

| Signal | Default weight | Source |
| --- | --- | --- |
| locality | 3.0 | config (Local=1.0, same-region Remote=0.7, cross-region=0.4) |
| queue_depth | 3.0 | Prometheus / CRDT (future) |
| kv_cache | 2.0 | Prometheus / CRDT (future) |
| prefix_cache | 2.0 | Prometheus / CRDT (future) |
| latency | 2.0 | local measurement |
| cost | 1.0 | config |

Scores are clamped to `[0.0, 1.0]` per signal before weighting. Unhealthy
backends are filtered before scoring. Equal scores use first-configured order
(policy tiebreak is a future decision).

---

## Validated demo results

| Demo step | Command | Result |
| --- | --- | --- |
| Provider inference baseline | `env verify-providers` | **15/15 PASS** |
| Provider gateway ext_proc | `env verify-provider-gateways` | **16/16 PASS** |
| Consumer G2G static config | `env verify-gateway-e2e` | **8/8 PASS** |
| Consumer G2G overlay config | `env verify-gateway-e2e --overlay-config` | **8/8 PASS** |
| mTLS trust enforcement | `env verify-mtls-trust` | **9/10** (known kind flake) |

---

## What is not yet implemented

| Gap | Status |
| --- | --- |
| Live HTTP health probe loop | Design ready (OP-05); not wired |
| Metrics-driven freshness (queue depth, KV cache, latency) | No Prometheus integration |
| SWIM/CRDT gossip | Design only; no controller wiring |
| Gateway annotation patching | Blocked — target object type unknown |
| `/v1/responses` full E2E | Route layer is path-agnostic; inference-sim has no handler |
| MCP tool routing in kind demo | Praxis PR ready; xtask consumer config not wired |
| A2A routing | Explicitly deferred |
| Production SPIFFE/SPIRE identity | Demo uses generated certs |
| Dynamic failover | Requires Operator health loop |
