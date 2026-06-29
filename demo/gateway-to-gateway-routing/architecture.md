# Gateway-to-gateway E2E architecture

## Goal

Build the smallest useful three-gateway validation for Epic #664:
gateway-to-gateway connectivity, peer trust, site metadata, and cross-gateway
inference/tool routing. A2A is represented by mocks only and remains deferred
until explicit A2A route-key semantics and gateway tests are defined.

This E2E is deliberately a prerequisite validation. It is not the final PR
stack. It is the evidence used to decide the PR stack.

## Runtime topology

```text
 site-a
 ┌──────────────────────────────────────────────────────────────┐
 │ client --> public Praxis listener                            │
 │              │                                               │
 │              ├─ local route --> site-a inference mock         │
 │              │                                               │
 │              ├─ mTLS cluster --> site-b grid listener         │
 │              │                                               │
 │              └─ mTLS cluster --> site-c grid listener         │
 └──────────────────────────────────────────────────────────────┘

 site-b
 ┌──────────────────────────────────────────────────────────────┐
 │ grid Praxis listener requires client cert from site-a         │
 │              │                                               │
 │              ├─ inference mock                               │
 │              ├─ MCP tool mock                                │
 │              └─ A2A agent mock                               │
 └──────────────────────────────────────────────────────────────┘

 site-c
 ┌──────────────────────────────────────────────────────────────┐
 │ grid Praxis listener requires client cert from site-a         │
 │              │                                               │
 │              ├─ inference mock                               │
 │              ├─ MCP tool mock                                │
 │              └─ A2A agent mock                               │
 └──────────────────────────────────────────────────────────────┘
```

## Trust boundaries

| Boundary | Rule |
| --- | --- |
| Public client to site A | Client has no gateway authority. Any internal route headers are stripped or rejected. |
| Site A to site B/C | Site A must present a gateway client certificate. |
| Site B/C grid ingress | Peer certificate identity must map to an allowed origin site. |
| Destination gateway to local backend | Internal gateway metadata is not forwarded to final backends unless explicitly allowed. |

## Route scenarios

| Scenario | Request | Expected route |
| --- | --- | --- |
| Local inference | Chat request for a site A model | site A public listener → site A inference mock |
| Remote inference by capability | Chat request for a site B-only model | site A public listener → mTLS → site B grid listener → site B inference mock |
| Remote inference by freshness/locality | Model exists in B and C, but C is stale or lower score | site B wins |
| Spoofed internal header | Public request includes gateway route headers | Header ignored/stripped; route still follows trusted metadata |
| Missing mTLS | Client calls site B grid listener directly without cert | Rejected during TLS or ingress trust validation |
| MCP tool | JSON-RPC/MCP request for a site C tool | site A → mTLS → site C → tool mock |
| A2A agent | A2A request for a site B agent | Deferred; mocks exist, but cross-gateway A2A routing is not claimed until route-key/session semantics and tests exist. |

## Suggested implementation shape

The selected architecture is a typed `grid_route` filter backed by an
immutable local routing snapshot. `grid_route` parses bounded request facts,
scores validated candidates from that snapshot, and sets `ctx.cluster`.
Existing Praxis clusters, load balancing, timeouts, TLS, and mTLS then own
the actual connection to either a local backend or a remote gateway.

The E2E branch can temporarily implement a small set of POC primitives:

1. peer identity exposure from downstream mTLS;
2. ingress trust/internal-header protection;
3. static gateway site/capability snapshot shaped like the future
   Operator-rendered `RoutingSnapshot`;
4. route selection that sets `ctx.cluster`;
5. internal route metadata injection for gateway-to-gateway hops; and
6. destination-side validation and local forwarding.

Keep these implementation areas visibly separated in files and docs. The goal
is not to make one polished mega-PR. The goal is to learn the correct seams for
the later PR stack.

## Masterless local-snapshot architecture

There is no master node, leader election, central coordinator, or central
registry in the request path. Each Praxis gateway makes routing decisions
locally from its own validated config/snapshot.

```text
Client request
  → local Praxis gateway
  → parse request facts (model name, MCP tool name)
  → read immutable local snapshot (static config today)
  → score candidates deterministically
  → select local or remote cluster
  → forward via existing Praxis upstream/mTLS

No request-time Operator, SWIM, Kubernetes, database, or metrics lookup.
```

In production, the **AI Grid Operator** will own dynamic snapshot updates:

```text
AI Grid Operator
  - watches Kubernetes resources
  - consumes SWIM/CRDT liveness summaries
  - consumes policy and capability state
            |
            v
  renders local gateway snapshot/config
            |
            v
  Praxis validates + hot reloads atomically
            |
            v
  New requests read latest accepted local snapshot
  In-flight requests finish on previous snapshot
```

SWIM, CRDT, Kubernetes, and metrics are inputs the Operator may consume.
Praxis never queries them directly during request handling.

## Fault tolerance: current state vs future

The demo architecture is **masterless** but is **not dynamically fault
tolerant** yet:

- The demo uses static config with static candidate snapshots.
- If site-b is configured as the selected target and site-b goes down,
  site-a will still try that route until the config is updated.
- `fresh: true/false` is a static POC signal. It demonstrates scoring
  behavior but is not automatically updated by health or liveness signals.
- Existing Praxis cluster-level health checks and circuit breakers can
  help for ordinary upstream endpoints, but dynamic remote-site eligibility
  is not wired into `grid_route` yet.
- Dynamic failover belongs in the Operator-driven snapshot update path.

Avoid claiming: "fully fault tolerant," "automatic failover,"
"self-healing," or "live liveness-based routing." The correct description
is **fault-tolerance-ready architecture with static POC freshness signals**.

## What happens when a snapshot changes

Today, the snapshot is represented by static Praxis YAML config. Changing
it means editing the config file and relying on Praxis hot reload (file
watcher, 500ms debounce, atomic pipeline swap).

In production:

1. The AI Grid Operator renders a new local gateway config/snapshot.
2. Praxis validates the new config before accepting it.
3. If valid, Praxis atomically swaps the filter pipeline.
4. New requests read the new accepted config.
5. In-flight requests finish on the previous pipeline view.
6. If the new config fails validation, the previous config stays active.

The Operator runs outside the request path. It may consume Kubernetes
resource watches, SWIM/CRDT membership state, metrics summaries, and
policy state — but those are Operator inputs, not Praxis request-path
dependencies.

## Demo evidence format

Each run should produce a concise `sample-output.md` containing:

- command line used;
- source revisions;
- pass/fail summary table;
- route decision excerpts with no prompts, secrets, private keys, or full bodies;
- any known deviations from the intended architecture; and
- extraction notes for future PRs.
