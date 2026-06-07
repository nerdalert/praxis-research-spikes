# Praxis Research Spikes

This repository collects research spikes and implementation demos for Praxis.

## llm-d Track Naming

### Track A: Praxis-native scheduling

Track A is the `praxis-native` path.

Request path:

`Client -> Praxis llmd_endpoint_picker -> selected backend`

In Track A, Praxis owns the llm-d scheduling decision in process. Praxis buffers and parses the OpenAI-compatible request body, extracts the requested model, evaluates endpoint state and scoring inputs, selects the upstream, and forwards directly to the backend.

Track A removes Envoy, the Envoy `ext_proc` hop, and the external Go EPP process from the request path. It answers: "What happens if Praxis becomes the native llm-d scheduler?"

### Track B: Praxis proxy with Go EPP

Track B is the `praxis-go-epp` path.

Request path:

`Client -> Praxis llmd_external_epp -> Go EPP -> selected backend`

In Track B, Praxis replaces Envoy as the proxy/runtime, but the existing Go EPP remains the scheduling brain. Praxis buffers the request body, sends an Envoy ext_proc-compatible request-phase call to Go EPP, reads the selected endpoint from the EPP response, sets the Praxis upstream, and forwards the original request to the selected backend.

Track B does not eliminate Go EPP. It answers: "What happens if Praxis replaces Envoy while keeping the existing Go EPP scheduler?"

### Baseline: Envoy with Go EPP

The baseline is the `envoy-go-epp` path.

Request path:

`Client -> Envoy ext_proc -> Go EPP -> selected backend`

This is the current comparison path. Envoy receives the client request, calls Go EPP through Envoy `ext_proc`, applies the selected destination, and forwards to the backend. It answers: "What does the current Envoy plus Go EPP architecture cost?"

### Control: generic Praxis proxy

The control profile is `praxis-simple`.

Request path:

`Client -> Praxis generic proxy -> backend`

This is not an llm-d scheduler. It is the generic Praxis forwarding baseline used to estimate base Praxis proxy overhead for the same request shape.

## llm-d

### Implementation Demos

### [Track A: Native Praxis Scheduler](demo/llm-d-track-a/)

Praxis replaces Envoy and the external Go EPP with the in-process `llmd_endpoint_picker`. Validates model-aware routing, load-based scoring, KV-cache utilization, prefix-cache affinity, saturation/admission, P/D hints, and policy metadata.

---

### [Track B: Praxis with Go EPP](demo/llm-d-track-b/)

Praxis replaces Envoy, but keeps the existing Go EPP scheduler through `llmd_external_epp`. Validates ext_proc-compatible gRPC callout, streamed body handling, endpoint selection, fail-closed behavior, local smoke, and KIND deployment.

### Benchmark Results

### [llm-d Performance Benchmarks](demo/llm-d-benchmarks/)

Consolidated benchmark suite comparing Track A `praxis-native`, Track B `praxis-go-epp`, generic `praxis-simple`, and the current `envoy-go-epp` baseline. Includes Vegeta throughput/latency, GuideLLM TTFT/ITL/token metrics, large-prompt body handling, and simulator echo results.

## Other Demos

### [Responses API Agentic Loop](demo/v1-responses/)

Validates the Praxis-owned Responses API agentic orchestration loop where Praxis acts as the orchestration engine between the client and the model.

---

### [A2A Task Routing](demo/a2a-task-routing/)

Validates local A2A task-ownership routing, including task capture from SendMessage responses, follow-up routing by task ID, fallback for unknown tasks, and spoofing rejection.

## Spikes

### [Stateful Proxy Analysis](stateful-proxy/)

Research and proposal material for Praxis state management across request metadata, local runtime state, shared hot-path state, durable business state, and configuration state.

## Repository Layout

Each spike lives in its own subdirectory. The subdirectory `README.md` is the primary spike document. Supporting research notes and implementation plans are stored alongside it.
