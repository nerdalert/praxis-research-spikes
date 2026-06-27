# Praxis Research Spikes

This repository collects research spikes and implementation demos for Praxis.

## llm-d Integration PoC

### [Praxis ext_proc with Go EPP](demo/llm-d-track-b/)

Praxis replaces Envoy as the proxy data plane while keeping the existing
Go EPP scheduler. Praxis uses the generic Envoy-compatible `ext_proc` filter
with one full-duplex `ExternalProcessor.Process` stream per HTTP request.
The Go EPP returns the selected endpoint as a trusted header mutation, and
the generic `endpoint_selector` filter sets the Praxis upstream.

`Client -> Praxis ext_proc -> Go EPP -> endpoint_selector -> selected backend`

This is the current refinement path for llm-d request routing. The
accompanying benchmark material provides context for understanding
data-plane performance tradeoffs.

### [llm-d Performance Benchmarks](demo/llm-d-benchmarks/)

Benchmark suite comparing `praxis-ext-proc-full-duplex-go-epp` against the
current `envoy-go-epp` baseline. Includes Vegeta throughput/latency,
large-prompt body handling, GuideLLM simulator echo, and analysis.

## Other Demos

### [Gateway-to-Gateway Routing E2E](demo/gateway-to-gateway-routing/)

Validation workspace for the gateway-to-gateway connectivity, metadata, and
routing epic. Proves the full three-gateway path before upstream PRs are split.

---

### [Responses API Agentic Loop](demo/v1-responses/)

Validates the Praxis-owned Responses API agentic orchestration loop where Praxis acts as the orchestration engine between the client and the model.

---

### [Native `/v1/responses` Passthrough](demo/v1-responses-passthrough/)

Validates native Responses passthrough, Codex-facing model alias rewrite/default injection, SSE preservation, client-owned tool-loop traffic, mixed-format routing, and request-path benchmark profiles.

---

### [A2A Task Routing](demo/a2a-task-routing/)

Validates local A2A task-ownership routing, including task capture from SendMessage responses, follow-up routing by task ID, fallback for unknown tasks, and spoofing rejection.

## Spikes

### [Gateway-to-Gateway Routing Implementation Plan](research/gateway-to-gateway-routing/)

Implementation plan for the Praxis gateway-to-gateway connectivity, mTLS trust,
site metadata, and cross-gateway inference/agent routing epic.

### [Stateful Proxy Analysis](research/stateful-proxy/)

Research and proposal material for Praxis state management across request metadata, local runtime state, shared hot-path state, durable business state, and configuration state.

### [Agentic Loop](research/agentic-loop/)

End-to-end demo and implementation plan for the Praxis agentic orchestration loop.

## Repository Layout

Each spike lives in its own subdirectory. The subdirectory `README.md` is the primary spike document. Supporting research notes and implementation plans are stored alongside it.
