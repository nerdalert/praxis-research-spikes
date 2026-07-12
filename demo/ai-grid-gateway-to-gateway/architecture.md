# AI Grid — Architecture

## What this is

The AI Grid is a federated AI data plane. It routes inference requests and
eventually tool calls across clusters, providers, and sites, using local
routing snapshots and mTLS gateway identity for trust. The control plane
(Grid Operator) prepares those snapshots outside the request hot path.

This demo validates the data-plane shape with three kind clusters.

---

## Three-cluster topology

```text
                   ┌─────────────────────────────────────────────────────┐
                   │  cluster-a  (provider site)                         │
                   │  ┌─────────────────┐   ┌──────────────────────────┐│
                   │  │  Praxis AI       │   │  inference-sim            ││
                   │  │  (provider gw)  │──▶│  granite-3.3-8b           ││
                   │  │  ext_proc path  │   │  mistral-7b               ││
                   │  │  mock EPP       │   └──────────────────────────┘│
                   │  └────────┬────────┘                                │
                   └───────────┼─────────────────────────────────────────┘
                               │ mTLS (grid_ingress_trust)
client ──▶ cluster-c ──────────┤
           (consumer site)     │ mTLS (grid_ingress_trust)
           Praxis AI           │
           grid_route          │
           json_body_field     ├─────────────────────────────────────────┐
                               │  cluster-b  (provider site)             │
                               │  ┌─────────────────┐  ┌───────────────┐│
                               │  │  Praxis AI       │  │  inference-sim ││
                               └─▶│  (provider gw)  │─▶│  llama-3.2-8b ││
                                  │  ext_proc path  │  └───────────────┘│
                                  │  mock EPP       │                    │
                                  └─────────────────┘                    │
                                  └──────────────────────────────────────┘
```

- **cluster-a** — provider site; hosts `granite-3.3-8b` and `mistral-7b`.
- **cluster-b** — provider site; hosts `llama-3.2-8b`.
- **cluster-c** — consumer site; entry point for client requests; routes to
  cluster-a or cluster-b based on model name.

All inter-cluster traffic crosses mutual TLS enforced by the Grid CA and the
`grid_ingress_trust` Praxis filter at each provider gateway.

---

## Request path (step by step)

```text
1. Client → POST /v1/chat/completions { "model": "granite-3.3-8b", ... }

2. Consumer gateway (cluster-c)
   - json_body_field extracts "model" → X-Model: granite-3.3-8b
   - grid_route reads local candidate list
   - grid_route selects cluster-a as the target Praxis cluster
   - mTLS connection to cluster-a provider gateway

3. Provider gateway (cluster-a)
   - grid_ingress_trust validates peer certificate (org = ai-grid)
   - ext_proc opens full-duplex gRPC stream to mock EPP
   - mock EPP selects per-model inference-sim endpoint
   - endpoint_selector forwards to correct inference-sim pod

4. inference-sim → returns HTTP 200 chat completions JSON

5. Response flows back: inference-sim → provider gw → consumer gw → client
```

No request-time database lookup, no Operator query, no SWIM/CRDT call in the
hot path. Every decision comes from a local routing snapshot or static config.

---

## Trust layers

```text
Layer 1: TLS
  Provider gateway requires a client certificate.
  No client cert → TLS handshake failure before HTTP.

Layer 2: PKI
  Provider gateway validates the client cert against the Grid CA.
  Unknown CA → TLS handshake failure before HTTP.

Layer 3: Filter
  grid_ingress_trust reads the verified peer identity from mTLS context.
  Checks OrganizationName against the configured allow list (demo: "ai-grid").
  Same-CA wrong-org → HTTP 403 from the filter layer.
```

The demo generates a small local CA. Each cluster gets a site certificate
signed by that CA. The wrong-org cert is also CA-signed but carries
`O=not-ai-grid`, proving the filter layer is the enforcement point, not just
TLS chain validation.

---

## Control plane vs data plane

```text
Control plane (Grid Operator — runs outside the request path)
  ├── watches GridNetwork, GridSite, InferenceProvider CRDs
  ├── renders RoutingOverlay ConfigMaps per gateway
  ├── sets per-gateway local_site via GatewayRef.localSiteName
  └── future: SWIM/CRDT health aggregation → overlay freshness

Data plane (Praxis AI — request hot path, reads local snapshot only)
  ├── grid_route: selects target cluster from local candidates
  ├── grid_ingress_trust: enforces peer identity at provider gateways
  ├── json_body_field: extracts model name from request body
  └── ext_proc + endpoint_selector: llm-d-style backend selection
```

**The demo uses static config in place of a live Operator.** The `--overlay-config`
flag wires in a JSON file matching the operator wire format, proving the
RoutingOverlay contract without a live Kubernetes Operator.

---

## Operator overlay wire format

The `grid-config.json` format consumed by `deploy-consumer-gateway --overlay-config`:

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
    }
  ]
}
```

The Grid Operator renders this JSON into a ConfigMap. The demo reads it from
a local file. The demo xtask uses `gateway-{site}` naming to match existing
load balancer naming conventions; `candidate.cluster` is validated but not
used in YAML generation (Phase 1 demo simplification).

---

## What the demo does not prove

| Not proven | Why |
|---|---|
| Live Operator reconciliation | Demo reads a local JSON file, not a ConfigMap |
| Gateway annotation patching | Target Kubernetes object type not yet confirmed |
| SWIM/CRDT gossip | Design only; no distributed state in this demo |
| Real llm-d scheduler | inference-sim simulates model endpoints |
| Production SPIFFE/SPIRE identity | Demo uses generated local certs (O=ai-grid) |
| Metrics-driven freshness | Static `fresh` flag only; no Prometheus integration |
| `/v1/responses` full E2E | Route layer is API-shape agnostic; backend handler added to mock-providers; inference-sim does not yet support this path |
| A2A routing | Explicitly deferred |

---

## Repository layout

| Repo | Role | What lives there |
|---|---|---|
| `praxis-proxy/grid` | Reusable xtask + certs + operator | `env up/down/verify-*`, scoring, CRD types |
| `praxis-proxy/ai` | Praxis AI gateway with llm-d ext_proc | gateway image, ext_proc filter, mock EPP |
| `praxis-proxy/praxis` | Praxis gateway core | `grid_route`, `grid_ingress_trust`, `json_body_field` |
| `nerdalert/praxis-research-spikes` | Demo assets (this repo) | demo narrative, configs, overlay JSON, scripts |

**This directory** is where opinionated demo topology, presenter scripts, and
hardcoded demo configs belong. Production/reusable implementation belongs in
the three `praxis-proxy/*` repos.
