# Praxis Research Spikes

This repository collects research spikes and implementation demos for Praxis.

## llm-d Integration PoC

### Track B: Praxis generic ext_proc with Go EPP

Track B is the `praxis-ext-proc-full-duplex-go-epp` path.

Request path:

`Client -> Praxis ext_proc -> Go EPP -> endpoint_selector -> selected backend`

In Track B, Praxis replaces Envoy as the proxy/runtime, but the existing Go EPP remains the scheduling brain. Praxis uses the generic Envoy-compatible `ext_proc` filter with one full-duplex `ExternalProcessor.Process` stream per HTTP request. The Go EPP returns the selected endpoint as a trusted header mutation, and the generic `endpoint_selector` filter sets the Praxis upstream.

This does **not** eliminate Go EPP. It answers: "What happens if Praxis replaces Envoy while keeping the existing Go EPP scheduler?"

### Baseline: Envoy with Go EPP

The baseline is the `envoy-go-epp` path.

Request path:

`Client -> Envoy ext_proc -> Go EPP -> selected backend`

This is the current comparison path. Envoy receives the client request, calls Go EPP through Envoy `ext_proc`, applies the selected destination, and forwards to the backend. It answers: "What does the current Envoy plus Go EPP architecture cost?"

## llm-d

### Implementation Demos

### [Track B: Praxis Full-Duplex ext_proc with Go EPP](demo/llm-d-track-b/)

Praxis keeps the existing Go EPP scheduler through the generic `ext_proc`
filter and one full-duplex `ExternalProcessor.Process` stream. Validates local
and KIND request routing, endpoint-header security and stripping, semantic body
preservation without duplication, one Process invocation per request, failure,
and recovery. This is the only Track B implementation path currently being
refined; benchmark material is context for data-plane performance tradeoffs.

### Benchmark Results

### [llm-d Performance Benchmarks](demo/llm-d-benchmarks/)

Consolidated benchmark suite comparing Track A `praxis-native`, Track B
`praxis-ext-proc-full-duplex-go-epp`, and the current `envoy-go-epp`
baseline. Includes Vegeta throughput/latency, large-prompt body handling,
and simulator echo results. GuideLLM is pending on this host.

## Other Demos

### [Responses API Agentic Loop](demo/v1-responses/)

Validates the Praxis-owned Responses API agentic orchestration loop where Praxis acts as the orchestration engine between the client and the model.

---

### [Native `/v1/responses` Passthrough](demo/v1-responses-passthrough/)

Validates native Responses passthrough, Codex-facing model alias rewrite/default injection, SSE preservation, client-owned tool-loop traffic, mixed-format routing, and request-path benchmark profiles.

---

### [A2A Task Routing](demo/a2a-task-routing/)

Validates local A2A task-ownership routing, including task capture from SendMessage responses, follow-up routing by task ID, fallback for unknown tasks, and spoofing rejection.

## Spikes

### [Stateful Proxy Analysis](stateful-proxy/)

Research and proposal material for Praxis state management across request metadata, local runtime state, shared hot-path state, durable business state, and configuration state.

## Repository Layout

Each spike lives in its own subdirectory. The subdirectory `README.md` is the primary spike document. Supporting research notes and implementation plans are stored alongside it.
