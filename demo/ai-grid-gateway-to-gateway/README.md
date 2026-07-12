# AI Grid — Gateway-to-Gateway Demo

## Purpose

Validate the AI Grid multi-cluster data-plane architecture in a three-cluster
kind environment. This demo proves that a consumer gateway can route
OpenAI-compatible inference requests across clusters, using mTLS for gateway
identity and trust, and the AI Grid Operator wire format for routing config.

This directory stores demo-specific assets — narrative scripts, overlay
configs, sample requests, and presenter walkthroughs. Production and reusable
implementation belongs in `praxis-proxy/grid`, `praxis-proxy/ai`, and
`praxis-proxy/praxis`.

See [architecture.md](architecture.md) for system design details.
See [demo-narrative.md](demo-narrative.md) for the presenter walkthrough.
See [upstream-pr-stack.md](upstream-pr-stack.md) for the PR extraction map.

---

## Plain-language summary

A client sends one OpenAI-compatible inference request to a consumer gateway.
The consumer gateway reads a local routing table, selects the provider cluster
that hosts the requested model, and forwards the request over mTLS. The
provider gateway enforces peer identity before routing to a backend. The
client does not know which cluster serves the model.

```text
Client → cluster-c (consumer) → mTLS → cluster-a or cluster-b (provider)
                                        → ext_proc → mock EPP → inference-sim
```

---

## Source repos

| Repo | Branch | What it provides |
|---|---|---|
| `praxis-proxy/grid` | `main` (dirty worktree: `prs/` dirs) | xtask commands, certs, operator |
| `praxis-proxy/ai` | `llmd-ext-proc` build | gateway image, ext_proc, mock EPP |
| `praxis-proxy/praxis` | extraction worktrees at `prs/04-07-*` | `grid_route`, `grid_ingress_trust` filters |
| This repo | `codex/gateway-to-gateway-demo` | demo assets (this directory) |

---

## Prerequisites

| Requirement | Verified version |
|---|---|
| kind | v0.31.0 |
| kubectl | present |
| Docker or Podman | 29.x |
| Rust stable toolchain | 1.96.0 (`cargo +1.96.0`) |
| Grid repo at `GRID_REPO` | `/home/ubuntu/praxxis/ai-grid/grid` (default) |
| `localhost/praxis-ai:llmd-ext-proc` image | built via `env build-gateway-images` |
| `localhost/praxis-ai-mock-epp:latest` image | built via `env build-gateway-images` |

Run the prereq check:
```console
bash scripts/check-prereqs.sh
```

Build gateway images if not yet present:
```console
cd "${GRID_REPO}"
cargo +1.96.0 run -p xtask -- env build-gateway-images \
  --ai-repo /path/to/ai-repo
```

---

## Full demo sequence

All commands run from the Grid repo (`cd "${GRID_REPO}"`).

```console
# Stage 1: environment setup and provider baseline
cargo +1.96.0 run -p xtask -- env up
cargo +1.96.0 run -p xtask -- env status
cargo +1.96.0 run -p xtask -- env verify-providers

# Stage 2: provider gateways
cargo +1.96.0 run -p xtask -- env load-gateway-images
cargo +1.96.0 run -p xtask -- env deploy-provider-gateways
cargo +1.96.0 run -p xtask -- env verify-provider-gateways

# Stage 3: consumer gateway — static routing
cargo +1.96.0 run -p xtask -- env probe-gateway-network
cargo +1.96.0 run -p xtask -- env deploy-consumer-gateway
cargo +1.96.0 run -p xtask -- env verify-gateway-e2e

# Stage 4: consumer gateway — operator overlay config
cargo +1.96.0 run -p xtask -- env deploy-consumer-gateway \
  --overlay-config /tmp/grid-demo-overlay.json
cargo +1.96.0 run -p xtask -- env verify-gateway-e2e

# Stage 5: mTLS trust verification
cargo +1.96.0 run -p xtask -- env verify-mtls-trust

# Teardown
cargo +1.96.0 run -p xtask -- env down
```

Or use the demo script:
```console
GRID_REPO=/path/to/grid bash scripts/run-full-demo.sh
```

---

## Expected results

| Demo | Command | Expected |
|---|---|---|
| Provider baseline | `env verify-providers` | **15/15 PASS** |
| Provider gateways | `env verify-provider-gateways` | **16/16 PASS** |
| Consumer G2G static | `env verify-gateway-e2e` | **8/8 PASS** |
| Consumer G2G overlay | `env verify-gateway-e2e` | **8/8 PASS** |
| mTLS trust | `env verify-mtls-trust` | **9/10 or 10/10** |

The mTLS 9/10 result is a known kind port-forward timing issue, not a filter
defect. See the caveat in [demo-narrative.md](demo-narrative.md#demo-5).

---

## Cleanup

```console
cargo +1.96.0 run -p xtask -- env down
# or
bash scripts/cleanup.sh
```

Post-cleanup check:
```console
kind get clusters          # should show no grid-cluster-* entries
pgrep -af kubectl          # should show no port-forward processes
```

---

## Status matrix

| Demo | Current state | Repo dependency | Command | Expected result | Known gaps |
|---|---|---|---|---|---|
| Provider inference baseline | **READY** | `praxis-proxy/grid` xtask | `env verify-providers` | 15/15 | none |
| Provider gateway ext_proc | **READY** | `praxis-proxy/ai` image | `env verify-provider-gateways` | 16/16 | Requires pre-built image |
| Consumer G2G static | **READY** | Praxis `grid_route` (local) | `env verify-gateway-e2e` | 8/8 | none |
| Consumer G2G overlay | **READY** | Grid `operator_overlay.rs` | `env verify-gateway-e2e` | 8/8 | File input only; no live ConfigMap |
| mTLS trust | **READY-WITH-CAVEAT** | Praxis `grid_ingress_trust` (local) | `env verify-mtls-trust` | 9/10 or 10/10 | kind port-forward timing flake |
| `/v1/responses` mock | **MOCK READY** | `praxis-proxy/grid` mock-providers | — | — | inference-sim backend missing handler; no live E2E |
| Metrics/freshness routing | **NOT STARTED** | OP-05 (future) | — | — | No Prometheus integration |
| MCP tool routing | **PR READY (PRAXIS)** | Praxis `grid_route` MCP PR | — | — | xtask consumer config not wired for mcp_tool |
| Operator overlay renderer | **PR READY** | Operator OPERATOR-01/03 | — | — | No live ConfigMap fetch; annotation patching blocked |
| CRDT/SWIM propagation | **DESIGN ONLY** | future | — | — | No controller wiring |
| A2A routing | **NOT IN SCOPE** | deferred | — | — | Explicit deferral |

---

## Slide deck mapping

Maps each demo to the corresponding slide in `ai-grid-slides-v1.txt`.

| Demo | Slide | Slide title |
|---|---|---|
| Provider inference baseline | DEMO 1 | Provider Inference Baseline |
| Provider gateway ext_proc | DEMO 2 | Provider Gateway ext_proc / llm-d Path |
| Consumer G2G static | DEMO 3 | Consumer G2G Static Routing |
| Consumer G2G overlay | DEMO 4 | Consumer G2G with Operator Overlay File |
| mTLS trust | DEMO 5 | mTLS Trust Enforcement |
| Full E2E sequence | DEMO 6 | Full End-to-End Demo Sequence |
| `/v1/responses` routing assessment | DEMO 7 | /v1/responses Route-Layer Compatibility |
| Metrics/freshness | DEMO 8 | Metrics / Freshness Route Shift |
| MCP routing | DEMO 9 | MCP Tool Routing |
| Operator overlay renderer | DEMO 10 | Operator Overlay Renderer |
| CRDT/SWIM | DEMO 11 | CRDT / SWIM State Propagation |
| A2A | DEMO 12 | OpenShell / A2A Agent Routing (deferred) |

Architecture slides INTRO 4–8 map to [architecture.md](architecture.md).

---

## What the demo proves

| Proof point | Evidence |
|---|---|
| Three kind clusters run concurrently | `env up` completes; `env status` reports all ready |
| Per-model inference-sim serves Chat Completions | `verify-providers`: 15/15 |
| Praxis AI ext_proc + mock EPP path | `verify-provider-gateways`: 16/16 |
| Consumer gateway routes `granite-3.3-8b` → cluster-a | `verify-gateway-e2e`: model-routing assertion |
| Consumer gateway routes `llama-3.2-8b` → cluster-b | `verify-gateway-e2e`: cross-cluster assertion |
| Unknown model fails closed (404) | `verify-gateway-e2e`: fail-closed assertion |
| Operator overlay JSON drives routing | `verify-gateway-e2e` with `--overlay-config`: 8/8 |
| No client cert → TLS rejection | `verify-mtls-trust`: no-cert assertion |
| Wrong CA cert → TLS rejection | `verify-mtls-trust`: wrong-CA assertion |
| Same-CA wrong-org → HTTP 403 | `verify-mtls-trust`: wrong-org assertion (9/10 in kind) |
| `mock-providers` serves `/v1/responses` | PR candidate: 34 tests, clean clippy |

---

## What the demo does not prove

| Not proven | Why |
|---|---|
| Live Operator reconciliation | Demo reads a local JSON file, not a live ConfigMap |
| Gateway annotation patching | Target Kubernetes object type not yet confirmed |
| Production SPIFFE/SPIRE identity | Demo uses generated certs with `O=ai-grid` |
| Metrics-driven freshness | Static `fresh` flag; no Prometheus/vLLM integration |
| `/v1/responses` full E2E | Route layer works; inference-sim has no handler |
| A2A routing | Explicitly deferred |
| SWIM/CRDT state propagation | Design only |
| Dynamic failover | Requires Operator health loop (OP-05) |

---

## Production / demo boundary

**Production and reusable implementation belongs in:**

- `praxis-proxy/grid` — xtask commands, scoring engine, certs library,
  operator CRD types and controllers
- `praxis-proxy/ai` — Praxis AI gateway, llm-d ext_proc, mock EPP
- `praxis-proxy/praxis` — `grid_route`, `grid_ingress_trust`, core filters

**Opinionated demo topology, presenter scripts, manifests, and narrative
belong here** (`nerdalert/praxis-research-spikes/demo/ai-grid-gateway-to-gateway/`):

- hardcoded demo overlay JSON
- sample curl requests
- run/cleanup scripts wrapping xtask commands
- presenter walkthrough and Q&A
- slide-deck alignment
- demo-specific status tracking

Do not commit production planning notes, implementation code, or non-demo
config to this directory.

---

## Files in this directory

| File | Purpose |
|---|---|
| [README.md](README.md) | Entry point, topology, commands, status matrix, slide mapping |
| [architecture.md](architecture.md) | System design, request path, trust layers, operator model |
| [demo-narrative.md](demo-narrative.md) | Presenter walkthrough for each demo scenario |
| [upstream-pr-stack.md](upstream-pr-stack.md) | PR extraction map across all repos |
| [configs/example-overlay.json](configs/example-overlay.json) | Sample operator RoutingOverlay JSON |
| [configs/sample-requests.sh](configs/sample-requests.sh) | Reference curl commands |
| [scripts/run-full-demo.sh](scripts/run-full-demo.sh) | Full demo sequence script |
| [scripts/check-prereqs.sh](scripts/check-prereqs.sh) | Prerequisite checker |
| [scripts/cleanup.sh](scripts/cleanup.sh) | Teardown helper |
