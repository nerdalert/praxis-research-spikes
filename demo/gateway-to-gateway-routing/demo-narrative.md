# Gateway-to-gateway demo narrative

Presenter script for the Praxis gateway-to-gateway E2E spike.

This is the demo story. The technical proof lives in `scripts/run-demo.sh`,
`sample-output.md`, `architecture.md`, and `pr-extraction-map.md`.

## Demo intent

Show that the gateway-to-gateway architecture for
[`praxis-proxy/praxis#664`](https://github.com/praxis-proxy/praxis/issues/664)
is understandable, defensible, and validated before upstream PR work begins.

This demo is not a PR. It is the evidence-gathering step before we split the
work into production PRs. The demo implementation source is:

**POC branch:** [`nerdalert/praxis@praxis-multi-cluster-poc-v1`](https://github.com/nerdalert/praxis/tree/praxis-multi-cluster-poc-v1)

**Plain-language summary:** this demo shows one Praxis gateway safely handing an
AI request to another Praxis gateway, while proving that untrusted traffic and
spoofed routing input do not get a free pass.

## What to say first

Use this opening:

```text
This demo validates the gateway-to-gateway foundation for AI Grid.

We are not showing the full AI Grid product yet. We are showing the data-plane
pieces Praxis needs first: gateway identity, trust at the receiving gateway,
local routing facts, deterministic route selection, scoring, and MCP tool
routing.

The important design choice is that request routing reads a local validated
snapshot. The request does not query Kubernetes, a database, an Operator, or
SWIM while the user is waiting. Any future Operator or SWIM layer updates the
snapshot outside the hot path.
```

## Audience mental model

Describe the system as three jobs:

| Job | Plain meaning | Demo representation |
| --- | --- | --- |
| Gateway trust | "Is the other gateway really who it claims to be?" | mTLS plus `grid_ingress_trust`. |
| Local routing map | "What sites can serve which models or tools?" | Static demo config acting as the routing snapshot. |
| Request routing | "Given this request, where should it go?" | `grid_route` selects local or remote Praxis clusters. |

**Plain-language summary:** certificates prove identity, the local map says what
is available, and the route filter chooses the safe destination.

## Architecture walkthrough

Show this topology from the README:

```text
client
  |
  v
site-a Praxis
  - public listener :18100
  - grid listener   :18101, mTLS
  - local inference/MCP/A2A mocks
  |
  | mTLS gateway-to-gateway links
  |
  +--> site-b Praxis :18110, mTLS grid listener
  |      - local inference/MCP/A2A mocks
  |
  +--> site-c Praxis :18120, mTLS grid listener
         - local inference/MCP/A2A mocks
```

Talking points:

1. Site A is the entry gateway the application calls.
2. Sites B and C represent other trusted sites.
3. Every grid listener requires mTLS.
4. The destination gateway still verifies the peer identity before doing work.
5. Backends are mocks because this demo validates routing and trust, not GPU
   inference quality.

## Snapshot and control-plane explanation

This is the part to clarify if people ask about the distributed nature of AI
Grid.

```text
In the demo, the routing snapshot is static config.

In the future, an AI Grid Operator or another control-plane process can update
that snapshot. It may learn state from Kubernetes, metrics, SWIM gossip, or
another store. But those updates happen before a request is routed.

The request itself only reads the latest accepted local snapshot.
```

Use this diagram:

```text
Future control plane / static config
  -> build full routing snapshot
  -> validate it
  -> atomically publish it to Praxis
  -> requests read it locally
```

Do not describe the design as:

```text
request arrives
  -> Praxis asks Operator/SWIM/database who has the model
  -> request waits
  -> route
```

**Plain-language summary:** update the map in the background; do not ask the map
maker while the user is waiting.

## Commands to run

From the demo directory:

```console
cd /home/ubuntu/praxxis/ai-grid/praxis-research-spikes/demo/gateway-to-gateway-routing

bash scripts/check-prereqs.sh
bash scripts/generate-certs.sh
bash scripts/run-demo.sh
```

If a specific Praxis binary is needed:

```console
PRAXIS_BIN=/path/to/praxis bash scripts/run-demo.sh
```

If the environment was interrupted:

```console
bash scripts/cleanup.sh
rm -rf .pids .logs
```

## Demo flow and narration

### 1. Prerequisites and certificates

Expected behavior:

- prerequisite check passes;
- cert generation creates the local demo CA, site certificates, trusted client
  cert, untrusted client cert, and unknown-CA cert.

Say:

```text
We generate a small local certificate universe for the demo. This lets us prove
three separate cases: trusted gateway, CA-valid but wrong gateway identity, and
unknown CA.
```

### 2. Mock backend health

Expected output:

```text
Mock backend health:
  PASS  mock :18001 responds
  ...
```

Say:

```text
The mocks represent local inference, MCP, and A2A services at each site. The
demo starts them first so routing failures are not confused with backend startup
failures.
```

### 3. Local routing through site A

Expected proof:

- `local-model` routes to site A's local inference mock.
- health request also reaches site A.

Say:

```text
First we prove the gateway still works locally. If the nearest site can serve
the request, there is no reason to cross the grid.
```

### 4. mTLS enforcement on grid listeners

Expected proof:

- plain HTTP to grid listeners fails;
- HTTPS without a client certificate fails.

Say:

```text
The grid listener is not a public endpoint. A client cannot simply call site B
or site C directly and pretend to be another gateway.
```

### 5. Ingress trust with verified peer identity

Expected proof:

- trusted site A client certificate is accepted by B and C;
- CA-valid wrong-organization cert is rejected with 403;
- unknown-CA cert is rejected by the TLS layer.

Say:

```text
mTLS proves the peer certificate. The ingress trust filter then applies a local
allow-list. This is important because "has a certificate" and "is allowed to
send grid traffic" are related but not identical.
```

Important distinction:

| Case | Meaning |
| --- | --- |
| Trusted cert accepted | Peer is known and allowed. |
| Wrong org rejected with 403 | TLS chain may be valid, but the gateway identity is not trusted by policy. |
| Unknown CA rejected | TLS cannot establish trust at all. |

### 6. Reserved header spoofing protection

Expected proof:

- public request with `x-praxis-grid-origin` is rejected with 400.

Say:

```text
Clients cannot create gateway authority by sending internal-looking headers.
Gateway identity comes from mTLS, not request headers.
```

### 7. Inference route selection

Expected proof:

- `local-model` routes to site A;
- `site-b-model` routes across mTLS to site B;
- `site-c-model` routes across mTLS to site C;
- `unknown-model` returns 404.

Say:

```text
Now we show the routing map being used. The route filter reads request facts and
the local snapshot, then selects a Praxis cluster. Existing Praxis forwarding
does the actual delivery.
```

Layman explanation:

```text
The app asks for a model. Site A checks its map. If the model is local, keep it
local. If the best valid candidate is at site B or C, forward to that gateway.
If no candidate exists, reject cleanly.
```

### 8. Freshness and local preference

Expected proof:

- fresh local beats stale remote;
- fresh remote beats stale remote;
- local wins when candidates are otherwise equal.

Say:

```text
This is not just first-match routing. The demo proves the scoring rules
separately: freshness matters, and locality is a tie-breaker when everything
else is equal.
```

Important caveat:

```text
The demo uses simple static freshness. Production should move to timestamped
freshness or generation-based summaries before treating this as dynamic grid
state.
```

### 9. MCP tool routing

Expected proof:

- JSON-RPC MCP `tools/call` for `weather-lookup` routes to site C.

Say:

```text
Gateway-to-gateway is not only for model inference. The same pattern can route
tool calls. Here we route based on MCP metadata instead of a model name.
```

### 10. A2A deferred

Expected output:

```text
SKIP  A2A request routed across gateway boundary by grid_route
```

Say:

```text
This skip is intentional. The epic includes agent traffic, but the validated
slice is MCP first. A2A should not be claimed until we have explicit A2A route
tests.
```

## Final expected output

The clean demo should end with:

```text
=== Summary ===
  Passed:              29
  Failed:              0
  Not implemented yet: 1

RESULT: PASS (all implemented assertions passed)
```

Interpretation:

| Count | Meaning |
| --- | --- |
| 29 pass | Implemented G2G trust/routing/scoring/MCP assertions passed. |
| 0 fail | No implemented behavior regressed. |
| 1 skip | A2A route validation is still deferred. |

## What the demo proves

| Area | Proven |
| --- | --- |
| Gateway process topology | Three local Praxis gateways can run as separate sites. |
| mTLS enforcement | Grid listeners are not public plain HTTP endpoints. |
| Peer trust | Destination gateways can accept trusted peers and reject untrusted peers. |
| Header safety | Public clients cannot spoof internal `x-praxis-*` authority. |
| Local/remote inference | Requests can stay local or cross to a remote gateway. |
| Deterministic scoring | Freshness and locality behavior are separately asserted. |
| MCP routing | Tool calls can cross gateway boundaries through the same trust path. |
| PR-stack evidence | The behavior maps to small upstream implementation slices. |

## What the demo does not prove

Do not overclaim these:

| Not proven | Why |
| --- | --- |
| Full AI Grid Operator | The demo uses static config/snapshots. |
| SWIM/CRDT distribution | No gossip or replicated state is implemented here. |
| Request-time database routing | Intentionally not part of the design. |
| Production policy engine | No deny-by-default tenant/agent policy engine yet. |
| llm-d worker scheduling | Mocks replace GPU workers and Endpoint Picker integration. |
| External provider fallback | Not in this demo. |
| A2A routing | Explicitly skipped. |
| Final forwarding metadata contract | Only bounded filter metadata is partially validated. |

## How to answer likely questions

### Are we querying a database, Operator, or SWIM on every request?

No. The request reads local validated state. Future Operator/SWIM/database
pieces may update the snapshot in the background, but not while the request is
waiting.

### What is the current "database" of site records?

For the demo, static YAML/config is the source. It stands in for the routing
snapshot that a future Operator would publish.

### Why not put SWIM in Praxis now?

Because Epic #664 scopes Praxis to the gateway data plane and configuration
surface. SWIM/operator orchestration is a separate project. Keeping that out of
the request path makes the proxy easier to test and safer to operate.

### Is llm-d part of this demo?

Not directly. llm-d is the local inference scheduling layer. In a complete AI
Grid deployment, gateway-to-gateway routing can choose a site or local inference
pool, then llm-d can choose the best worker inside that pool.

### Why static snapshots first?

Static snapshots make the behavior deterministic and reviewable. Once the data
model and route behavior are stable, a dynamic updater can replace the snapshot
without changing the request-path contract.

### Are we ready to open PRs?

No. The workflow rule is:

```text
finish and validate the full spike demo narrative
  -> review demo evidence and gaps
  -> only then split upstream PR-sized tasks
```

No commit, push, or PR should happen until explicitly requested.

## Demo operator checklist

Quick reference for running the demo end to end.

**Prerequisites:**

- Praxis binary built from POC branch: `nerdalert/praxis@praxis-multi-cluster-poc-v1`
- `openssl`, `python3`, `curl`
- No processes on ports 18001-18003, 18011-18013, 18021-18023, 18100-18101, 18110, 18120

Demo reviewers should build against the POC branch or use `PRAXIS_BIN` override.

**Command sequence:**

```console
cd praxis-research-spikes/demo/gateway-to-gateway-routing
bash scripts/cleanup.sh || true
rm -rf certs .pids .logs
bash scripts/check-prereqs.sh
bash scripts/generate-certs.sh
bash scripts/run-demo.sh
bash scripts/cleanup.sh
```

**Expected result:**

```text
Passed:              29
Failed:              0
Not implemented yet: 1
RESULT: PASS
```

The single SKIP is A2A routing (intentionally deferred).

**What not to claim:**

- A2A routing is not implemented.
- No Operator, SWIM, CRDT, or gossip is implemented.
- No request-time database or control-plane query.
- Freshness is static `true`/`false`, not timestamped.
- Forwarding metadata is bounded filter metadata only, not a finalized contract.
- The POC code is not PR-ready.

**Workflow rule:**

- Do not commit, push, or open PRs from the spike repo.
- The spike is evidence only. Upstream work uses the extraction map.

## Demo close

Use this closing:

```text
The spike validates the gateway-to-gateway foundation: trusted mTLS ingress,
local routing records, deterministic route selection, scoring, and MCP tool
routing.

The architecture keeps distributed state out of the request path. Praxis reads
the latest local validated snapshot. Future Operator or SWIM work can update
that snapshot in the background.

The next step is not to upstream this spike wholesale. The next step is to use
the extraction map to turn the validated behavior into small, reviewable
production PRs after the demo is fully accepted.
```
