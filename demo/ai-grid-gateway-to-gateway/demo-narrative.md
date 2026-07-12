# AI Grid — Demo Narrative

Presenter script for the AI Grid gateway-to-gateway kind demo.

This document is the *story*. The runnable proof is in `scripts/run-full-demo.sh`
and the architecture details are in `architecture.md`.

---

## Opening

Use this framing:

```text
This demo validates the AI Grid data-plane architecture in a three-cluster
kind environment. We are showing real cluster boundaries, real mTLS identity,
and real gateway-to-gateway routing — not local process mocks.

The core claim is: a client calls one OpenAI-compatible endpoint. The grid
routes that request to the provider cluster that hosts the requested model,
across mutual TLS, without the client knowing cluster topology.
```

---

## Demo 1 — Provider Inference Baseline

**User story:** As a platform engineer, I want every configured model to have a
ready backend endpoint before testing routing.

**Why it matters:** This isolates backend health from routing and gateway
issues. A provider inference failure is a different problem from a routing
failure.

**What to run:**
```console
cargo +1.96.0 run -p xtask -- env up
cargo +1.96.0 run -p xtask -- env verify-providers
```

**What to point out:**
- `env up` creates three kind clusters (cluster-a, cluster-b, cluster-c),
  deploys per-model inference-sim pods, and generates mTLS site certificates.
- `verify-providers` port-forwards to each model's service and probes
  `/v1/models` and `/v1/chat/completions`.
- Each model appears on the correct cluster: granite and mistral on cluster-a,
  llama on cluster-b.

**Expected output:** `15/15 PASS`

**What this proves:** Three kind clusters are up, each model has a running
backend, and all Chat Completions endpoints respond correctly.

**What this does not prove:** Gateway routing, mTLS trust, or operator
integration. That is added in the next steps.

**Failure modes and recovery:**
- `kind cluster not found` — run `kind delete cluster --name <name>` and retry.
- `pod not ready` — `env up` retries rollouts; wait for all providers to
  stabilize.
- `image pull failure` — inference-sim is pulled from `ghcr.io/llm-d/llm-d-inference-sim`.
  Ensure internet access or pre-pull the image.

---

## Demo 2 — Provider Gateway with llm-d ext_proc Path

**User story:** As an inference platform owner, I want the Praxis AI gateway
to front llm-d-style routing without trusting client-supplied routing headers.

**Why it matters:** This proves the AI-owned ext_proc compatibility layer
works through a real gateway path. Backend selection is owned by the mock EPP,
not the client.

**What to run:**
```console
cargo +1.96.0 run -p xtask -- env load-gateway-images
cargo +1.96.0 run -p xtask -- env deploy-provider-gateways
cargo +1.96.0 run -p xtask -- env verify-provider-gateways
```

**What to point out:**
- `load-gateway-images` loads `localhost/praxis-ai:llmd-ext-proc` and
  `localhost/praxis-ai-mock-epp:latest` into each kind cluster.
- `deploy-provider-gateways` deploys the Praxis AI gateway, mock EPP, and
  per-model services to cluster-a and cluster-b.
- `verify-provider-gateways` sends requests through the full ext_proc path
  and asserts correct responses for each model.

**Expected output:** `16/16 PASS`

**Architecture to show:**
```text
request → Praxis AI gateway
           → ext_proc (full-duplex gRPC) → mock EPP selects endpoint
           → endpoint_selector validates mutation
           → inference-sim backend
```

**What this proves:** The llm-d ext_proc compatibility layer works. The
gateway correctly routes to per-model backends. Spoofed destination headers
are ignored (endpoint_selector strips them).

**What this does not prove:** Cross-cluster routing or mTLS trust.

**Prerequisites:** `localhost/praxis-ai:llmd-ext-proc` must exist.
Build it with:
```console
cargo +1.96.0 run -p xtask -- env build-gateway-images --ai-repo <path-to-ai-repo>
```

**Failure modes and recovery:**
- `image not found` — run `env build-gateway-images` first.
- `rollout timeout` — pod scheduling in kind is occasionally slow; retry.

---

## Demo 3 — Consumer Gateway-to-Gateway Static Routing

**User story:** As an application team, I want one consumer gateway endpoint
to reach models hosted across multiple provider clusters.

**Why it matters:** This is the core multi-cluster routing value proposition.
The client calls cluster-c; the grid finds cluster-a or cluster-b.

**What to run:**
```console
cargo +1.96.0 run -p xtask -- env probe-gateway-network
cargo +1.96.0 run -p xtask -- env deploy-consumer-gateway
cargo +1.96.0 run -p xtask -- env verify-gateway-e2e
```

**What to point out:**
- `probe-gateway-network` checks cross-cluster Docker network connectivity
  and exposes provider NodePorts.
- `deploy-consumer-gateway` deploys the consumer Praxis AI to cluster-c with
  a static `grid_route` config mapping models to provider clusters.
- `verify-gateway-e2e` sends granite, mistral, and llama requests through the
  consumer gateway and verifies each arrives at the correct cluster.

**Expected output:** `8/8 PASS`

**Route table (static config):**
| Model | Routes to |
|---|---|
| granite-3.3-8b | cluster-a |
| mistral-7b | cluster-a |
| llama-3.2-8b | cluster-b |
| unknown-model | 404 (fail closed) |

**Request path to show:**
```text
client → cluster-c consumer gateway
           json_body_field: "model" → X-Model header
           grid_route: selects cluster-a or cluster-b
           mTLS → provider gateway
           grid_ingress_trust: validates peer cert
           ext_proc → mock EPP → inference-sim
```

**What this proves:** Cross-cluster routing with mTLS. The consumer gateway
reads a local route table and forwards to the correct provider gateway.
Unknown models fail closed.

**What this does not prove:** Operator-driven routing (added next) or
automatic failover.

**Failure modes and recovery:**
- `network probe failed` — cluster Docker networking is occasionally slow;
  retry `probe-gateway-network`.
- `NodePort not reachable` — confirm the Docker bridge network is shared
  across clusters.

---

## Demo 4 — Consumer G2G with Operator Overlay File

**User story:** As an operator developer, I want the same JSON snapshot
produced by the AI Grid Operator to drive gateway route decisions.

**Why it matters:** This bridges the demo from hand-authored static config
toward the production operator reconciliation path. The overlay wire format
is the contract between the operator and the gateway.

**What to run:**
```console
# Copy the example overlay or supply your own
cp configs/example-overlay.json /tmp/grid-demo-overlay.json

cargo +1.96.0 run -p xtask -- env deploy-consumer-gateway \
  --overlay-config /tmp/grid-demo-overlay.json
cargo +1.96.0 run -p xtask -- env verify-gateway-e2e
```

**What to point out:**
- The overlay JSON file is the same format the Grid Operator writes as a
  ConfigMap (`grid-config.json`).
- `local_site: "cluster-c"` tells the consumer gateway its own identity.
- `candidates[]` drives `grid_route` instead of the static xtask config.
- `verify-gateway-e2e` is the same 8-assertion suite as Demo 3.

**Expected output:** `8/8 PASS`

**What this proves:** The operator wire format is functionally correct. The
xtask reads a JSON file, validates it, and generates the correct Praxis
`grid_route` config stanza.

**What this does not prove:** Live ConfigMap fetch from Kubernetes, Gateway
annotation patching, or any direct Operator-to-gateway communication. The
xtask reads a local file only.

**Failure modes and recovery:**
- `invalid overlay` — validate JSON with `python3 -m json.tool
  /tmp/grid-demo-overlay.json`.
- `site not in providers` — overlay `site` values must match the clusters
  deployed by `env up` (cluster-a, cluster-b, cluster-c).

---

## Demo 5 — mTLS Trust Enforcement

**User story:** As a security reviewer, I want valid grid peers accepted and
wrong or missing identity rejected before traffic reaches model backends.

**Why it matters:** Cross-site federation must have an enforceable trust
boundary. "Has a valid certificate" and "is trusted to send grid traffic" are
related but not identical.

**What to run:**
```console
cargo +1.96.0 run -p xtask -- env verify-mtls-trust
```

**What to point out:**
- Five assertions per provider cluster: port-forward open, valid cert
  accepted, no cert rejected, wrong-CA cert rejected, same-CA wrong-org cert
  rejected (HTTP 403 from `grid_ingress_trust` filter).
- The wrong-org cert is signed by the same Grid CA but carries
  `O=not-ai-grid`. It passes the TLS layer and fails at the filter layer.
- `grid_ingress_trust` is the enforcement point that distinguishes "valid cert
  from a different org" from "valid cert from a trusted peer."

**Expected output:** `9/10 or 10/10 PASS`

**Known caveat:** The same-CA wrong-org assertion on one cluster occasionally
gets a TLS error instead of HTTP 403. This is a kind port-forward timing issue
in the test harness. The filter is correct — the same assertion passes on the
other cluster in the same run. This is documented and accepted.

**Three-layer trust table:**
| Case | Layer that rejects | Status |
|---|---|---|
| No client certificate | TLS handshake | Always fails |
| Wrong CA certificate | TLS chain validation | Always fails |
| Same-CA wrong org | `grid_ingress_trust` filter (HTTP 403) | 9/10 in kind |
| Valid peer cert (org=ai-grid) | Accepted | Always passes |

**What this proves:** The mTLS + filter trust stack is active. A legitimate
grid peer is accepted. Certs from a wrong org are rejected at the correct
layer. Unknown CAs are rejected before HTTP.

**What this does not prove:** Production SPIFFE/SPIRE identity. The demo uses
generated certs (`O=ai-grid`). In production, SVID-based identity replaces
this OrganizationName check.

---

## Demo 6 — OpenAI `/v1/responses` Route-Layer Compatibility

**User story:** As a product manager, I want to know whether supporting the
Responses API requires router work or backend handler work.

**What to explain (not run as live E2E):**

The Praxis `grid_route` filter is API-shape agnostic. It reads the model name
from a request header (`X-Model`) and selects a cluster. The path
(`/v1/chat/completions` vs `/v1/responses`) does not affect routing.

The Grid `mock-providers` binary (not the inference-sim used in this demo) now
implements `POST /v1/responses`. This covers the mock layer for unit testing
and CI.

The full E2E `/v1/responses` path — client → consumer gateway → provider
gateway → backend that returns a valid Responses-shaped JSON — is **not yet
demonstrable** because inference-sim does not implement `/v1/responses`.

**What the mock-providers implementation proves:**
- Non-streaming Responses API response shape (correct `object`, `output[]`,
  `usage`, no `choices`).
- Streaming SSE with `response.created`, `response.output_text.delta`,
  `response.completed`, `[DONE]`.
- Bearer auth required (same as Chat Completions).
- Model echoed from request.

**What still needs to happen for full E2E:**
- Switch a provider backend from inference-sim to mock-providers, or
- Add `/v1/responses` support to llm-d-inference-sim upstream.

**Why it matters:** This makes the demo's API surface explicit. The router
works. The backend gap is documented and isolated.

---

## Closing

Use this closing:

```text
The demo proves the core AI Grid federation path: provider inference works,
provider gateways front llm-d-style backends, consumer gateways route
cross-cluster requests over mTLS, and the operator wire format can replace
static config.

The architecture keeps distributed state out of the request path. Praxis
reads the latest accepted local snapshot. The Grid Operator updates that
snapshot in the background.

The next step is extracting the validated behavior into reviewable PRs —
not upstreaming this demo wholesale. Each PR slice is already scoped in the
upstream PR stack.
```

---

## Common questions

**Are we querying a database or control plane on every request?**

No. `grid_route` reads local config/snapshot. The Operator updates the
snapshot outside the request path. The request never blocks on Kubernetes,
SWIM, CRDT, or a metrics service.

**What is the "database" of site records?**

In the demo, static config or the overlay JSON. In production, the Grid
Operator renders a RoutingOverlay ConfigMap from `GridNetwork`,
`GridSite`, and `InferenceProvider` CRDs.

**Why not dynamic failover?**

Dynamic failover requires the Operator to update the snapshot when a
provider becomes unhealthy. That path is not yet wired (OP-05). The demo
proves the routing and trust foundation; freshness and failover are the
next layer.

**What is inference-sim?**

`ghcr.io/llm-d/llm-d-inference-sim` is a lightweight OpenAI-compatible
HTTP server that simulates model endpoints. It is the demo backend for
each cluster. It does not do GPU inference.

**Why does the mTLS wrong-org test show 9/10?**

This is a kind port-forward timing issue. The filter (HTTP 403 response)
is correct — it has been proven on both clusters in separate runs. The flake
is in the test harness, not the implementation.
