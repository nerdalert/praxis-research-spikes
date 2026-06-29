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

The E2E branch can temporarily implement a small set of POC primitives:

1. peer identity exposure from downstream mTLS;
2. ingress trust/internal-header protection;
3. static gateway site/capability snapshot;
4. route selection that sets `ctx.cluster`;
5. internal route metadata injection for gateway-to-gateway hops; and
6. destination-side validation and local forwarding.

Keep these implementation areas visibly separated in files and docs. The goal
is not to make one polished mega-PR. The goal is to learn the correct seams for
the later PR stack.

## Demo evidence format

Each run should produce a concise `sample-output.md` containing:

- command line used;
- source revisions;
- pass/fail summary table;
- route decision excerpts with no prompts, secrets, private keys, or full bodies;
- any known deviations from the intended architecture; and
- extraction notes for future PRs.
